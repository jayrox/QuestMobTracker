-- Quest Mob Tracker (auto mode)
-- Reads your quest log and tracks every quest that has a kill objective
-- ("Kobold slain: 3/10") or an item-collection objective ("Mote of Myreal: 2/6").
--
-- Matching mobs to quests:
--   * kill objectives: the mob name comes straight from the objective text.
--   * item objectives: the mob is LEARNED when it drops that item for you.
-- Kills / XP / gold are recorded for every mob while a quest is active, so
-- anything from before a mob's first drop is counted once it is matched.

local ADDON = "QuestMobTracker"
local IDLE_AFTER = 60   -- seconds without quest activity before the active timer pauses

local db
local frame = CreateFrame("Frame")
local ui
local guidNames = {}
local cleuSeen = {}   -- debug: combat log subevents seen
local lastLoot = { token = 0 }
local lastLootSrc   -- {name=, at=} last corpse/object whose loot window we opened (outlives lastLoot)
local lootPatterns, xpPattern, moneyPatterns, slainSuffix, questDonePat, questExpPat, questMoneyPat
local scanErrShown   -- only report a quest-scan error once
-- This client can hand back "secret" values (e.g. a unit's GUID or name while it is restricted). A secret can't be
-- used as a table key, compared or pattern-matched, so unit lookups return nil for one and callers just skip it.
local rawGUID, rawName = UnitGUID, UnitName
local function NotSecret(v) return v ~= nil and not (issecretvalue and issecretvalue(v)) end
local function UGuid(unit) local v = rawGUID(unit); if NotSecret(v) then return v end end
local function UName(unit) local v = rawName(unit); if NotSecret(v) then return v end end


local function Version()
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local ok, v = pcall(function() return get and get(ADDON, "Version") end)
    return ok and v or "?"
end

local function print_(msg) print("|cff33ccff[QMT]|r " .. tostring(msg)) end

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------
local function GP(s, anchored)
    s = s:gsub("([%(%)%.%+%-%*%?%[%]%^%$%%])", "%%%1")
    s = s:gsub("%%%%s", "(.+)")
    s = s:gsub("%%%%d", "(%%d+)")
    if anchored then s = "^" .. s .. "$" end
    return s
end

local function FormatTime(sec)
    sec = math.floor(sec or 0)
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    local s = sec % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, s) end
    return string.format("%d:%02d", m, s)
end

local function Money(c)
    c = c or 0
    if GetCoinTextureString then return GetCoinTextureString(c) end
    return string.format("%dg %ds %dc", c / 10000, (c / 100) % 100, c % 100)
end

local function NewSession(title)
    return {
        title = title,
        active = true,
        elapsed = 0,        -- ACTIVE seconds (first kill onwards, only while working)
        idle = 0,           -- seconds spent waiting / between kills
        completeAt = nil,
        objectives = {},   -- { type=, name= }
        members = {},      -- mob names matched to this quest
        mobs = {},         -- name -> {kills,xp,copper,drops,items}
        dropGUIDs = {},
        totalXP = 0,
        totalCopper = 0,
    }
end

local function Mob(s, name)
    local m = s.mobs[name]
    if not m then
        m = { kills = 0, xp = 0, copper = 0, drops = 0, items = 0 }
        s.mobs[name] = m
    end
    return m
end

-- Every quest in the log tracks its own mobs and items, whichever quest is focused in the window:
-- a kill or pickup updates every quest it belongs to. Only mobs related to a quest are counted
-- for it. A mob we can't tie to a quest (no Questie entry, not named by an objective) is held in
-- memory only (never saved) and claimed once it drops the quest item.
local pending = {}   -- quest title -> mob name -> stats

local function Related(s, name)
    return s.members[name] or (s.known and s.known[name]) or (s.knownObjs and s.knownObjs[name])
end

-- stats table to add to for this mob: saved if related, otherwise the in-memory holding area
local function Stat(s, name)
    if Related(s, name) then return Mob(s, name) end
    -- not (yet) known to belong to this quest: hold it in memory. Questie's list can be incomplete,
    -- so a mob that later drops the quest item still gets its earlier kills and XP.
    local p = pending[s.title]
    if not p then p = {}; pending[s.title] = p end
    local m = p[name]
    if not m then m = { kills = 0, xp = 0, copper = 0, drops = 0, items = 0 }; p[name] = m end
    return m
end

-- the mob just became related: move whatever we held for it into the saved stats
local function Adopt(s, name)
    local p = pending[s.title]
    local held = p and p[name]
    if not held then return end
    p[name] = nil
    local m = Mob(s, name)
    for _, k in ipairs({ "kills", "xp", "copper", "drops", "items" }) do m[k] = m[k] + held[k] end
end

-- remembers every item a source dropped (for the row tooltip)
local function AddLoot(m, itemName, link, count)
    m.loot = m.loot or {}
    local e = m.loot[itemName]
    if not e then e = { count = 0 }; m.loot[itemName] = e end
    e.count = e.count + count
    e.link = link
end

local function ActiveSessions()
    local t = {}
    for _, s in pairs(db.quests) do
        if s.active then t[#t + 1] = s end
    end
    return t
end

---------------------------------------------------------------------------
-- Quest log scanning
---------------------------------------------------------------------------
local function ParseObjective(text, otype)
    if not text then return nil end
    -- supports "Name: 3/12", "3/12 Name" and "Name slain: 3/12"
    local name = text:match("^(.-):%s*%d+/%d+$") or text:match("^%d+/%d+%s+(.+)$")
    if not name then return nil end
    if otype == "monster" then
        name = name:gsub("%s+slain$", "")
        if slainSuffix and name:sub(-#slainSuffix) == slainSuffix then
            name = name:sub(1, #name - #slainSuffix)
        end
    end
    return name
end

-- Optional: Questie's database. Returns a set of mob names (or nil) for a quest.
local function QuestieMobs(questId)
    if not questId or not QuestieLoader or not QuestieLoader.ImportModule then return nil end
    local ok, result, result2 = pcall(function()
        local DB = QuestieLoader:ImportModule("QuestieDB")
        if not DB or not DB.QueryQuestSingle then return nil end
        local objectives = DB.QueryQuestSingle(questId, "objectives")
        if type(objectives) ~= "table" then return nil end
        local names, count = {}, 0
        local objects, ocount = {}, 0
        local function addObj(id)
            local name = id and DB.QueryObjectSingle and DB.QueryObjectSingle(id, "name")
            if name and not objects[name] then objects[name] = true; ocount = ocount + 1 end
        end
        local function addNpc(id)
            local name = id and DB.QueryNPCSingle(id, "name")
            if name and not names[name] then names[name] = true; count = count + 1 end
        end
        for _, o in ipairs(objectives[1] or {}) do addNpc(o[1]) end            -- creature objectives
        for _, o in ipairs(objectives[5] or {}) do                              -- kill credit objectives
            for _, id in ipairs(type(o[1]) == "table" and o[1] or {}) do addNpc(id) end
            addNpc(o[2])
        end
        for _, o in ipairs(objectives[2] or {}) do addObj(o[1]) end            -- object objectives
        for _, o in ipairs(objectives[3] or {}) do                              -- item objectives
            local drops = o[1] and DB.QueryItemSingle(o[1], "npcDrops")
            for _, id in ipairs(drops or {}) do addNpc(id) end
            local odrops = o[1] and DB.QueryItemSingle(o[1], "objectDrops")    -- items from world objects
            for _, id in ipairs(odrops or {}) do addObj(id) end
        end
        return count > 0 and names or nil, ocount > 0 and objects or nil
    end)
    if not ok then return nil end
    return result, result2
end

-- Optional (Questie): where the quest is handed in, as "Name" and a second line "Continent, Zone · x, y". Cached; a failed lookup
-- (database not ready, or no spawn data) is retried after 30s.
local destCache, destFailedAt = {}, {}
local function QuestDestination(questId)
    if not questId or not QuestieLoader or not QuestieLoader.ImportModule then return nil end
    if destCache[questId] then return destCache[questId] end
    if destFailedAt[questId] and GetTime() - destFailedAt[questId] < 30 then return nil end
    local ok, text = pcall(function()
        local DB = QuestieLoader:ImportModule("QuestieDB")
        local fin = DB and DB.QueryQuestSingle and DB.QueryQuestSingle(questId, "finishedBy")
        if type(fin) ~= "table" then return nil end
        local npcId = type(fin[1]) == "table" and fin[1][1] or nil
        local objId = type(fin[2]) == "table" and fin[2][1] or nil
        local name, spawns
        if npcId then
            name, spawns = DB.QueryNPCSingle(npcId, "name"), DB.QueryNPCSingle(npcId, "spawns")
        elseif objId then
            name, spawns = DB.QueryObjectSingle(objId, "name"), DB.QueryObjectSingle(objId, "spawns")
        end
        if not name then return nil end
        local parts = { name }
        if type(spawns) == "table" then
            local areaId
            for id, pts in pairs(spawns) do   -- lowest area id with a real point, so the choice is stable
                if type(pts) == "table" and pts[1] and (pts[1][1] or -1) > 0 and (not areaId or id < areaId) then areaId = id end
            end
            if areaId then
                local pt = spawns[areaId][1]
                local ZoneDB = QuestieLoader:ImportModule("ZoneDB")
                local mapId = ZoneDB and ZoneDB.GetUiMapIdByAreaId and ZoneDB:GetUiMapIdByAreaId(areaId)
                local info = mapId and C_Map and C_Map.GetMapInfo and C_Map.GetMapInfo(mapId)
                if info and info.name then
                    local continent
                    local cur, guard = info, 0
                    while cur and cur.parentMapID and cur.parentMapID ~= 0 and guard < 8 do
                        cur = C_Map.GetMapInfo(cur.parentMapID); guard = guard + 1
                        if cur and Enum and Enum.UIMapType and cur.mapType == Enum.UIMapType.Continent then continent = cur.name; break end
                    end
                    parts[#parts + 1] = (continent and (continent .. ", ") or "") .. info.name
                end
                parts[#parts + 1] = string.format("%.1f, %.1f", pt[1], pt[2])
            end
        end
        return parts[1] .. (parts[2] and ("\n" .. table.concat(parts, "  ·  ", 2)) or "")
    end)
    if ok and text then destCache[questId] = text; return text end
    destFailedAt[questId] = GetTime()
end

-- The quest's objective description ("Speak with X at Y"), for quests whose log shows no objective rows.
-- Needs the quest selected in the log, so the selection is put back; cached per quest.
local objTextCache = {}
local function QuestObjectiveText(index, questId)
    if objTextCache[questId] then return objTextCache[questId] end
    if not GetQuestLogQuestText then return nil end
    local ok, obj = pcall(function()
        local oldSel = GetQuestLogSelection and GetQuestLogSelection()
        if SelectQuestLogEntry then SelectQuestLogEntry(index) end
        local _, o = GetQuestLogQuestText(index)
        if oldSel and SelectQuestLogEntry then SelectQuestLogEntry(oldSel) end
        return o
    end)
    if ok and type(obj) == "string" and obj ~= "" then objTextCache[questId] = obj; return obj end
end

-- Reads the quest log with whichever API this client has.
-- Returns list of {title=, questId=, complete=, objs={ {type=,text=} }}
local function ReadQuestLog()
    local out = {}
    if C_QuestLog and C_QuestLog.GetInfo and C_QuestLog.GetNumQuestLogEntries then
        local n = C_QuestLog.GetNumQuestLogEntries()
        for i = 1, n do
            local info = C_QuestLog.GetInfo(i)
            if info and not info.isHeader and info.questID then
                local q = { title = info.title, questId = info.questID, objs = {} }
                q.complete = C_QuestLog.IsComplete and C_QuestLog.IsComplete(info.questID) or false
                local objs = C_QuestLog.GetQuestObjectives and C_QuestLog.GetQuestObjectives(info.questID) or {}
                for _, o in ipairs(objs) do q.objs[#q.objs + 1] = { type = o.type, text = o.text } end
                local hasText = false
                for _, o in ipairs(q.objs) do if o.text and o.text ~= "" then hasText = true end end
                if not hasText then q.text = QuestObjectiveText(i, info.questID) end
                out[#out + 1] = q
            end
        end
    elseif GetNumQuestLogEntries and GetQuestLogTitle then
        local oldSel = GetQuestLogSelection and GetQuestLogSelection()
        for i = 1, GetNumQuestLogEntries() do
            local title, _, _, isHeader, _, isComplete, _, questId = GetQuestLogTitle(i)
            if title and not isHeader then
                local q = { title = title, questId = questId, complete = (isComplete == 1 or isComplete == true), objs = {} }
                for j = 1, (GetNumQuestLeaderBoards(i) or 0) do
                    local text, otype = GetQuestLogLeaderBoard(j, i)
                    q.objs[#q.objs + 1] = { type = otype, text = text }
                end
                local hasText = false
                for _, o in ipairs(q.objs) do if o.text and o.text ~= "" then hasText = true end end
                if not hasText then q.text = QuestObjectiveText(i, questId) end
                out[#out + 1] = q
            end
        end
        if oldSel and SelectQuestLogEntry then SelectQuestLogEntry(oldSel) end
    end
    return out
end

-- calls f(...) and returns its result only if it is a positive number
local function Try(f, ...)
    local ok, v = pcall(f, ...)
    if ok and type(v) == "number" and v > 0 then return v end
end

-- Reward lookups hit the game API and Questie on every quest-log update, so cache them.
-- Hits are kept; misses are retried after 30s (Questie may not be ready yet).
local rewardCache = {}
local function CachedReward(kind, questId, fetch)
    if not questId then return nil end
    local key, now = kind .. ":" .. questId, GetTime()
    local c = rewardCache[key]
    if c and (c.v or now - c.at < 30) then return c.v end
    local v = fetch(questId)
    rewardCache[key] = { v = v, at = now }
    return v
end

-- XP the quest itself pays on turn-in. Tries the game's API, then Questie's XP module.
local function FetchRewardXP(questId)
    local v
    if GetQuestLogRewardXP then v = Try(GetQuestLogRewardXP, questId) end
    if not v and C_QuestLog and C_QuestLog.GetQuestLogRewardXP then v = Try(C_QuestLog.GetQuestLogRewardXP, questId) end
    if not v and QuestieLoader then
        local ok, QXP = pcall(function() return QuestieLoader:ImportModule("QuestXP") end)
        if ok and QXP and QXP.GetQuestLogRewardXP then v = Try(QXP.GetQuestLogRewardXP, questId) end
    end
    return v
end

-- Copper the quest pays on turn-in (game API, then Questie's DB).
local function FetchRewardMoney(questId)
    local v
    if GetQuestLogRewardMoney then v = Try(GetQuestLogRewardMoney, questId) end
    if not v and C_QuestLog and C_QuestLog.GetQuestLogRewardMoney then v = Try(C_QuestLog.GetQuestLogRewardMoney, questId) end
    if not v and QuestieLoader then
        local ok, DB = pcall(function() return QuestieLoader:ImportModule("QuestieDB") end)
        if ok and DB and DB.QueryQuestSingle then v = Try(DB.QueryQuestSingle, questId, "rewardMoney") end
    end
    return v
end

local function QuestRewardXP(questId) return CachedReward("xp", questId, FetchRewardXP) end
local function QuestRewardMoney(questId) return CachedReward("money", questId, FetchRewardMoney) end

local pendingXP = 0   -- reward XP of every completed quest in the log (not yet turned in)
local pendingList = {}  -- reward XP of each completed quest, for the bar dividers
local focusXP = 0   -- reward XP of the shown quest when it is not complete yet (purple bar segment)
local completeCount = 0   -- quests in the log that are complete (not yet turned in)
-- quest-related earnings since login (not saved): mob XP/gold of related mobs plus turn-in rewards
local login = { xp = 0, copper = 0, turnedIn = 0 }
local dbg = {}   -- debug counters for /qmt kills
local function Dbg(k, v) dbg[k] = v == nil and ((dbg[k] or 0) + 1) or v end

-- A quest is counted as completed only on a definite turn-in signal, never just because it left the log (an
-- abandoned quest leaves the log too, and this client's QUEST_TURNED_IN can come late or not at all):
--   1. the game's "<quest> completed." message   2. the QUEST_TURNED_IN event   3. Questie's API, if installed.
-- Whichever arrives first counts it; the others are skipped for the same title.
local turnedAt = {}
local titleById = {}     -- questId -> title, from the last scan
local PAIR_WINDOW = 3   -- seconds: a quest leaving the log and a quest reward line "at the same time"
local lastTurnInAt = -100
local reward = { at = -100, used = true }   -- latest quest reward line (Experience gained / Received money)
local left = {}                              -- quests that just left the log and haven't been explained yet

local function CountTurnIn(title, via)
    local now = GetTime()
    if turnedAt[title] and now - turnedAt[title] < 15 then return end
    turnedAt[title] = now
    lastTurnInAt = now
    -- a reward line belonging to this turn-in must not be matched with some other quest leaving the log
    if now - reward.at < PAIR_WINDOW then reward.used = true end
    for i = #left, 1, -1 do if left[i].title == title then table.remove(left, i) end end
    login.turnedIn = login.turnedIn + 1
    Dbg("turn-ins")
    if db and db.traceLoot then print_("turn-in trace: '" .. tostring(title) .. "' counted via " .. via) end
end

-- An abandoned quest pays nothing, so a quest leaving the log together with a quest reward line is a turn-in.
-- The two can arrive in either order.
local function TryPair()
    local now = GetTime()
    for i = #left, 1, -1 do if now - left[i].at > PAIR_WINDOW then table.remove(left, i) end end
    if reward.used or now - reward.at > PAIR_WINDOW or #left == 0 then return end
    reward.used = true
    local q = table.remove(left, 1)
    CountTurnIn(q.title, "left the log + reward line")
end

local function QuestLeftLog(title)
    left[#left + 1] = { title = title, at = GetTime() }
    TryPair()
end

local function QuestRewardSeen()
    local now = GetTime()
    reward.at = now
    -- already explained by a turn-in counted a moment ago (e.g. the "completed." message came first)?
    reward.used = now - lastTurnInAt < PAIR_WINDOW
    TryPair()
end

local function ScanQuests()
    local seen = {}
    local pend = 0
    local log = ReadQuestLog()
    wipe(pendingList)
    completeCount = 0
    for _, q in ipairs(log) do
        titleById[q.questId or 0] = q.title
        if q.complete then
            completeCount = completeCount + 1
            local r = QuestRewardXP(q.questId) or 0
            QuestRewardMoney(q.questId)   -- warm the cache while the quest is still in the log
            pend = pend + r
            if r > 0 then pendingList[#pendingList + 1] = r end
        end
    end
    pendingXP = pend
    for _, q in ipairs(log) do
        local title = q.title
        local objs = {}
        for _, o in ipairs(q.objs) do
            if o.type == "monster" or o.type == "item" or o.type == "object" or o.type == "event" then   -- "Chest examined", "Rune used" etc. too, so the quest can be focused
                local name = ParseObjective(o.text, o.type)
                if name then objs[#objs + 1] = { type = o.type, name = name, text = o.text } end
            end
        end
        if #objs > 0 or q.complete then   -- a ready-to-turn-in quest can have no countable objective left ("Return to X")
            seen[title] = true
            local s = db.quests[title]
            if not s or not s.active then
                if s then
                    db.history[#db.history + 1] = s
                    while #db.history > 20 do table.remove(db.history, 1) end
                end
                s = NewSession(title)
                db.quests[title] = s
                print_("Tracking '" .. title .. "'.")
            end
            s.objectives = objs
            s.questId = q.questId
            -- objective text the counters can't use ("Speak with X"), shown in place of the kill/drop line
            local other = {}
            for _, o in ipairs(q.objs) do
                if o.text and o.text ~= "" and not ParseObjective(o.text, o.type) then other[#other + 1] = o.text end
            end
            if #other == 0 and q.text then other[1] = q.text end
            s.otherText = #other > 0 and table.concat(other, "\n") or nil
            s.destination = (#objs == 0 and s.otherText) and QuestDestination(q.questId) or nil
            s.rewardXP = QuestRewardXP(q.questId) or s.rewardXP
            s.rewardMoney = QuestRewardMoney(q.questId) or s.rewardMoney
            s.isObject = s.isObject or {}
            if s.started == nil and s.elapsed > 5 then s.started = true end
            if not s.known and not s.knownObjs then
                s.known, s.knownObjs = QuestieMobs(q.questId)   -- nil until Questie's DB is ready
            end
            for _, o in ipairs(objs) do
                -- with Questie data, ignore "monster" objectives that aren't real mobs
                if o.type == "monster" and (not s.known or s.known[o.name]) then
                    s.members[o.name] = true
                end
            end
            -- mobs that became related (objective text, or Questie data arriving late)
            for name in pairs(pending[title] or {}) do
                if Related(s, name) then Adopt(s, name) end
            end
            s.complete = q.complete and true or false
            if not q.complete and s.completeAt then s.completeAt = nil end
            if q.complete and s.started and not s.completeAt then
                s.completeAt = s.elapsed
                print_("'" .. title .. "' objectives complete in " .. FormatTime(s.elapsed) .. ".")
            end
        end
    end

    for title, s in pairs(db.quests) do
        if s.active and not seen[title] then
            s.active = false
            QuestLeftLog(title)
            print_("'" .. title .. "' left your log. Total time in log " .. FormatTime(s.elapsed + (s.idle or 0))
                .. " (active " .. FormatTime(s.elapsed) .. ").")
        end
    end
end

local function Debug()
    local t = {}
    print_("Quest Mob Tracker v" .. Version())
    for k, v in pairs(cleuSeen) do t[#t + 1] = k .. "=" .. v end
    table.sort(t)
    print_("Combat log events seen: " .. (#t > 0 and table.concat(t, ", ") or "none"))
    print_("C_QuestLog.GetInfo: " .. tostring(C_QuestLog and C_QuestLog.GetInfo ~= nil)
        .. ", GetQuestLogTitle: " .. tostring(GetQuestLogTitle ~= nil)
        .. ", Questie: " .. tostring(QuestieLoader ~= nil))
    local log = ReadQuestLog()
    print_("Quests read: " .. #log)
    for _, q in ipairs(log) do
        print_(string.format("- %s (id %s) %d objective(s)", tostring(q.title), tostring(q.questId), #q.objs))
        for _, o in ipairs(q.objs) do print_(string.format("    [%s] %s", tostring(o.type), tostring(o.text))) end
    end
end

---------------------------------------------------------------------------
-- UI
---------------------------------------------------------------------------
local WHITE = "Interface\\Buttons\\WHITE8X8"
local ACCENT = { 1.0, 0.72, 0.25 }
local W, PAD, MAX_MOBS, MAX_OBJ = 372, 12, 5, 5
local scrollOffset, scrollTitle = 0, nil   -- source list scroll position
local OBJ_H = 14

-- red -> orange -> yellow -> green, the tracker's quest-difficulty colors; green only when complete
local PROGRESS_STOPS = { { 1, 0.20, 0.20 }, { 1, 0.50, 0.15 }, { 1, 0.82, 0.10 }, { 0.40, 1, 0.40 } }
local function ProgressColor(frac)
    frac = math.min(1, math.max(0, frac))
    if frac >= 1 then
        local c = PROGRESS_STOPS[4]
        return string.format("|cff%02x%02x%02x", math.floor(c[1] * 255), math.floor(c[2] * 255), math.floor(c[3] * 255))
    end
    local t = frac * 3                       -- 0..3 over the first three segments
    local i = math.min(3, math.floor(t) + 1)
    local a, b, f = PROGRESS_STOPS[i], PROGRESS_STOPS[i + 1], t - (i - 1)
    return string.format("|cff%02x%02x%02x", math.floor((a[1] + (b[1] - a[1]) * f) * 255),
        math.floor((a[2] + (b[2] - a[2]) * f) * 255), math.floor((a[3] + (b[3] - a[3]) * f) * 255))
end
local ROW_H = 18
local picked  -- session currently displayed

local function ShortMoney(c)
    c = math.floor(c or 0)
    local g, s, cc = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
    if g > 0 then return string.format("|cffffd700%dg|r |cffc7c7cf%ds|r", g, s) end
    if s > 0 then return string.format("|cffc7c7cf%ds|r |cffeda55f%dc|r", s, cc) end
    return string.format("|cffeda55f%dc|r", cc)
end

local function Ago(t)
    if not t then return "" end
    local d = time() - t
    if d < 60 then return "" end   -- "just now" is implied
    if d < 3600 then return math.floor(d / 60) .. "m ago" end
    return math.floor(d / 3600) .. "h ago"
end

-- coin text with the gold/silver/copper icons, like the game's own item tooltips
local function CoinText(c)
    c = math.floor((c or 0) + 0.5)
    -- Auctionator's padded format (62 [s] 02 [c]) when it's installed, so the numbers line up with its tooltips
    if Auctionator and Auctionator.Utilities and Auctionator.Utilities.CreatePaddedMoneyString then
        local ok, t = pcall(Auctionator.Utilities.CreatePaddedMoneyString, c)
        if ok and t then return t end
    end
    if GetCoinTextureString then
        local ok, t = pcall(GetCoinTextureString, c)
        if ok and t then return t end
    end
    return ShortMoney(c)
end

-- Per-item worth in copper: vendor sell price (game) and auction price (Auctionator, if installed).
local function ItemWorth(link, name)
    local vendor, ah
    local ref = link or name
    if ref then
        local ok, sell = pcall(function() return select(11, GetItemInfo(ref)) end)
        if ok and type(sell) == "number" then vendor = sell end
    end
    local API = Auctionator and Auctionator.API and Auctionator.API.v1
    if API and link then
        if API.GetAuctionPriceByItemLink then
            local ok, p = pcall(API.GetAuctionPriceByItemLink, "QuestMobTracker", link)
            if ok and type(p) == "number" and p > 0 then ah = p end
        end
    end
    return vendor, ah
end

-- totals over a loot table { [name] = {count=, link=} }: vendor value, and AH value (vendor where no AH data)
local function LootWorth(loot, vendorTotal, ahTotal, haveAH)
    for name, e in pairs(loot or {}) do
        local v, a = ItemWorth(e.link, name)
        vendorTotal = vendorTotal + (v or 0) * e.count
        if a then haveAH = true end
        ahTotal = ahTotal + (a or v or 0) * e.count
    end
    return vendorTotal, ahTotal, haveAH
end

local function Panel(parent, w, h, alpha)
    local f = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    f:SetSize(w, h)
    f:SetBackdrop({ bgFile = WHITE })
    f:SetBackdropColor(1, 1, 1, alpha or 0.06)
    return f
end

local function Text(parent, font, justify)
    local t = parent:CreateFontString(nil, "OVERLAY", font or "GameFontNormalSmall")
    t:SetJustifyH(justify or "LEFT")
    return t
end

local Refresh  -- forward declaration

local function BuildUI()
    ui = CreateFrame("Frame", "QMTFrame", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    ui:SetSize(W, 300)
    ui:SetPoint("CENTER", UIParent, "CENTER", 400, 100)
    ui:SetMovable(true)
    ui:EnableMouse(true)
    ui:SetClampedToScreen(true)
    ui:RegisterForDrag("LeftButton")
    ui:SetScript("OnDragStart", ui.StartMoving)
    ui:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local p, _, rp, x, y = self:GetPoint()
        db.pos = { p, rp, x, y }
    end)
    ui:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    ui:SetBackdropColor(0.06, 0.07, 0.09, db.alpha or 0.6)
    ui:SetBackdropBorderColor(0, 0, 0, math.min(1, (db.alpha or 0.6) + 0.2))
    ui:SetScale(db.scale or 0.85)

    -- accent line along the top
    local line = ui:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 1)
    line:SetPoint("TOPLEFT", 0, 0); line:SetPoint("TOPRIGHT", 0, 0); line:SetHeight(2)

    -- header
    ui.icon = ui:CreateTexture(nil, "ARTWORK")
    ui.icon:SetSize(22, 22)
    ui.icon:SetPoint("TOPLEFT", PAD, -10)
    ui.icon:SetTexture("Interface\\GossipFrame\\AvailableQuestIcon")
    ui.title = Text(ui, "GameFontNormalLarge")
    ui.title:SetPoint("LEFT", ui.icon, "RIGHT", 8, 0)
    ui.title:SetWidth(W - 150)
    ui.title:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
    ui.timer = Text(ui, "GameFontHighlight", "RIGHT")
    ui.timer:SetPoint("TOPRIGHT", ui, "TOPRIGHT", -40, -11)
    ui.idle = Text(ui, "GameFontNormalSmall", "RIGHT")
    ui.idle:SetPoint("TOPRIGHT", ui, "TOPRIGHT", -40, -26)
    ui.idle:SetTextColor(0.5, 0.52, 0.58)
    ui.close = CreateFrame("Button", nil, ui, "UIPanelCloseButton")
    ui.close:SetPoint("TOPRIGHT", 2, 0)
    ui.close:HookScript("OnClick", function() db.hidden = true end)

    -- stat tiles
    local labels = { "Kills", "Drops", "XP", "Gold" }
    local tw = (W - PAD * 2 - 6 * 3) / 4
    ui.tiles = {}
    for i, label in ipairs(labels) do
        local t = Panel(ui, tw, 54)
        t:SetPoint("TOPLEFT", PAD + (i - 1) * (tw + 6), -42)
        t.label = Text(t, "GameFontNormalSmall"); t.label:SetPoint("TOPLEFT", 8, -7)
        t.label:SetTextColor(0.62, 0.64, 0.7); t.label:SetText(label)
        t.value = Text(t, "GameFontHighlightLarge"); t.value:SetPoint("TOPLEFT", 8, -20)
        t.sub = Text(t, "GameFontNormalSmall"); t.sub:SetPoint("BOTTOMLEFT", 8, 6)
        t.sub:SetTextColor(0.5, 0.52, 0.58)
        ui.tiles[i] = t
    end
    -- Drops tile tooltip: what we saw drop vs what the quest log says
    ui.tiles[2]:EnableMouse(true)
    ui.tiles[2]:SetScript("OnEnter", function(self)
        local s = picked
        if not s or not self.qmtLog then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Quest items", 1, 0.82, 0)
        GameTooltip:AddDoubleLine("In quest log", tostring(self.qmtLog), 1, 1, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Seen dropping", tostring(self.qmtTracked or 0), 1, 1, 1, 1, 1, 1)
        if self.qmtLog > (self.qmtTracked or 0) then
            GameTooltip:AddLine((self.qmtLog - self.qmtTracked) .. " picked up before tracking or from an unseen source", 0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
    end)
    ui.tiles[2]:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- XP tile tooltip: mobs + quest reward = total
    ui.tiles[3]:EnableMouse(true)
    ui.tiles[3]:SetScript("OnEnter", function(self)
        local s = picked
        if not s then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Quest XP", 1, 0.82, 0)
        GameTooltip:AddDoubleLine("From mobs", tostring(self.qmtXP or 0), 1, 1, 1, 1, 1, 1)
        if s.rewardXP then
            GameTooltip:AddDoubleLine("Quest reward", tostring(s.rewardXP), 1, 1, 1, 1, 1, 1)
            GameTooltip:AddDoubleLine("Total so far + reward", tostring((self.qmtXP or 0) + s.rewardXP), 1, 0.82, 0, 1, 0.82, 0)
        else
            GameTooltip:AddLine("Quest reward XP not available", 0.6, 0.6, 0.6)
        end
        GameTooltip:AddDoubleLine("Per hour", string.format("%d", self.qmtPerHr or 0), 0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    ui.tiles[3]:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- Gold tile tooltip: mob gold + quest reward
    ui.tiles[4]:EnableMouse(true)
    ui.tiles[4]:SetScript("OnEnter", function(self)
        local s = picked
        if not s then return end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:AddLine("Quest gold", 1, 0.82, 0)
        GameTooltip:AddDoubleLine("From mobs", CoinText(self.qmtCopper or 0), 1, 1, 1, 1, 1, 1)
        local vt, at, haveAH = 0, 0, false
        for _, m in pairs(s.mobs) do vt, at, haveAH = LootWorth(m.loot, vt, at, haveAH) end
        if vt > 0 or at > 0 then
            GameTooltip:AddDoubleLine("Vendor", CoinText(vt), 1, 0.82, 0, 1, 1, 1)
            if haveAH then GameTooltip:AddDoubleLine("Auction", CoinText(at), 1, 0.82, 0, 1, 1, 1) end
        end
        if s.rewardMoney then
            GameTooltip:AddDoubleLine("Quest reward", CoinText(s.rewardMoney), 1, 1, 1, 1, 1, 1)
            GameTooltip:AddDoubleLine("Total so far + reward", CoinText((self.qmtCopper or 0) + s.rewardMoney), 1, 0.82, 0, 1, 0.82, 0)
        else
            GameTooltip:AddLine("Quest reward gold not available", 0.6, 0.6, 0.6)
        end
        GameTooltip:AddDoubleLine("Per hour", CoinText(self.qmtPerHr or 0), 0.7, 0.7, 0.7, 0.7, 0.7, 0.7)
        GameTooltip:Show()
    end)
    ui.tiles[4]:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- latest find card
    ui.card = Panel(ui, W - PAD * 2, 46, 0.08)
    ui.card:SetPoint("TOPLEFT", PAD, -104)
    local bar = ui.card:CreateTexture(nil, "ARTWORK")
    ui.cardBar = bar   -- gold; green once the quest is complete (set in Refresh)
    bar:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 1)
    bar:SetPoint("TOPLEFT"); bar:SetPoint("BOTTOMLEFT"); bar:SetWidth(3)
    ui.cardTitle = Text(ui.card, "GameFontHighlight"); ui.cardTitle:SetPoint("TOPLEFT", 14, -9)
    ui.cardSub = Text(ui.card, "GameFontNormalSmall"); ui.cardSub:SetPoint("TOPLEFT", 14, -26)
    ui.cardSub:SetTextColor(0.62, 0.64, 0.7)

    -- objective list (inside the card, above the latest line; positioned in Refresh)
    ui.objFS = {}
    for i = 1, MAX_OBJ do
        local fs = Text(ui.card, "GameFontHighlightSmall")
        fs:SetWidth(W - PAD * 2 - 24)
        ui.objFS[i] = fs
    end

    -- mob table (columns are offsets from the left of the row)
    local colX = { kills = 130, drops = 172, xp = 214, gold = 262 }
    local colW = { kills = 38, drops = 38, xp = 44, gold = 86 }
    local function Cols(row, header)
        local font = header and "GameFontNormalSmall" or "GameFontHighlightSmall"
        row.name = Text(row, font)
        row.name:SetPoint("LEFT", 0, 0); row.name:SetWidth(126)
        row.cols = {}
        for _, k in ipairs({ "kills", "drops", "xp", "gold" }) do
            local fs = Text(row, font, "RIGHT")
            fs:SetPoint("LEFT", colX[k], 0); fs:SetWidth(colW[k])
            row.cols[k] = fs
        end
    end
    ui.headRow = CreateFrame("Frame", nil, ui)
    ui.headRow:SetSize(W - PAD * 2, ROW_H)
    ui.headRow:SetPoint("TOPLEFT", PAD, -158)
    Cols(ui.headRow, true)
    ui.headRow.name:SetText("Source"); ui.headRow.name:SetTextColor(0.62, 0.64, 0.7)
    for k, label in pairs({ kills = "Kills", drops = "Drops", xp = "XP", gold = "Gold" }) do
        ui.headRow.cols[k]:SetText(label); ui.headRow.cols[k]:SetTextColor(0.62, 0.64, 0.7)
    end
    ui.rows = {}
    for i = 1, MAX_MOBS do
        local r = CreateFrame("Frame", nil, ui)
        r:EnableMouse(true)
        r:SetScript("OnEnter", function(self)
            local s, name = picked, self.srcName
            if not s or not name then return end
            local m = s.mobs[name]
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(name, 1, 0.82, 0)
            if m then
                GameTooltip:AddDoubleLine("Kills", tostring(m.kills), 0.7, 0.7, 0.7, 1, 1, 1)
                GameTooltip:AddDoubleLine("Drops", tostring(m.drops), 0.7, 0.7, 0.7, 1, 1, 1)
            end
            local list = {}
            for itemName, e in pairs(m and m.loot or {}) do list[#list + 1] = { name = itemName, e = e } end
            table.sort(list, function(a, b)
                if a.e.count ~= b.e.count then return a.e.count > b.e.count end
                return a.name < b.name
            end)
            if #list == 0 then
                GameTooltip:AddLine("No items recorded yet", 0.6, 0.6, 0.6)
            else
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine("Items dropped", 0.62, 0.64, 0.7)
                -- laid out like Auctionator's own item tooltip: link, then Vendor / Auction lines
                local hasAuctionator = Auctionator and Auctionator.API and Auctionator.API.v1
                for _, it in ipairs(list) do
                    local v, a = ItemWorth(it.e.link, it.name)
                    local n = it.e.count
                    local suffix = n > 1 and (" |cffffffff(x" .. n .. ")|r") or ""
                    GameTooltip:AddLine(it.e.link or it.name)
                    if v and v > 0 then
                        GameTooltip:AddDoubleLine("Vendor" .. suffix, "|cffffffff" .. CoinText(v * n) .. "|r")
                    end
                    if hasAuctionator then
                        GameTooltip:AddDoubleLine("Auction" .. suffix,
                            "|cffffffff" .. (a and CoinText(a * n) or "Unknown  ") .. "|r")
                    end
                end
                local vt, at, haveAH = LootWorth(m.loot, 0, 0, false)
                GameTooltip:AddLine(" ")
                GameTooltip:AddDoubleLine("Total vendor", "|cffffffff" .. CoinText(vt) .. "|r")
                if haveAH then
                    GameTooltip:AddDoubleLine("Total auction", "|cffffffff" .. CoinText(at) .. "|r")
                end
            end
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() GameTooltip:Hide() end)
        r:SetSize(W - PAD * 2, ROW_H)
        r:SetPoint("TOPLEFT", PAD, -158 - ROW_H * i)
        Cols(r, false)
        ui.rows[i] = r
    end
    ui.more = Text(ui, "GameFontNormalSmall"); ui.more:SetTextColor(0.5, 0.52, 0.58)
    ui:EnableMouseWheel(true)
    ui:SetScript("OnMouseWheel", function(_, delta)
        scrollOffset = scrollOffset - delta
        Refresh()
    end)

    -- footer
    ui.foot = Text(ui, "GameFontNormalSmall")
    ui.foot:SetTextColor(0.5, 0.52, 0.58)

    -- level progress bar: [current xp | xp from completed quests | remaining]
    local bw = W - PAD * 2
    ui.xpBar = CreateFrame("Frame", nil, ui)
    ui.xpBar:SetSize(bw, 6)
    ui.xpBar:EnableMouse(true)
    ui.xpBar.bg = ui.xpBar:CreateTexture(nil, "BACKGROUND")
    ui.xpBar.bg:SetAllPoints(); ui.xpBar.bg:SetColorTexture(1, 1, 1, 0.08)
    ui.xpBar.cur = ui.xpBar:CreateTexture(nil, "ARTWORK")
    ui.xpBar.cur:SetColorTexture(0.25, 0.55, 1, 0.95)
    ui.xpBar.cur:SetPoint("TOPLEFT"); ui.xpBar.cur:SetPoint("BOTTOMLEFT")
    ui.xpBar.pend = ui.xpBar:CreateTexture(nil, "ARTWORK")
    ui.xpBar.pend:SetColorTexture(0.3, 0.85, 0.4, 0.95)
    ui.xpBar.pend:SetPoint("TOPLEFT", ui.xpBar.cur, "TOPRIGHT"); ui.xpBar.pend:SetPoint("BOTTOMLEFT", ui.xpBar.cur, "BOTTOMRIGHT")
    ui.xpBar.focus = ui.xpBar:CreateTexture(nil, "ARTWORK")   -- reward of the shown quest, if not yet complete
    ui.xpBar.focus:SetColorTexture(0.72, 0.58, 1, 0.9)
    ui.xpBar.focus:SetPoint("TOPLEFT", ui.xpBar.pend, "TOPRIGHT"); ui.xpBar.focus:SetPoint("BOTTOMLEFT", ui.xpBar.pend, "BOTTOMRIGHT")
    ui.xpBar.div = {}
    ui.xpBar:SetScript("OnEnter", function(self)
        local xp, mx = UnitXP("player"), UnitXPMax("player")
        if not mx or mx <= 0 then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Level " .. (UnitLevel("player") or "?") .. " progress", 1, 0.82, 0)
        GameTooltip:AddDoubleLine("Current", string.format("%d / %d (%.0f%%)", xp, mx, xp / mx * 100), 0.4, 0.7, 1, 1, 1, 1)
        GameTooltip:AddDoubleLine("Completed quests", string.format("+%d (%.0f%%)", pendingXP, pendingXP / mx * 100), 0.4, 0.9, 0.5, 1, 1, 1)
        GameTooltip:AddDoubleLine("After turn-ins", string.format("%d / %d", xp + pendingXP, mx), 0.7, 0.7, 0.7, 1, 1, 1)
        if focusXP > 0 then
            GameTooltip:AddDoubleLine("If shown quest is done", string.format("+%d -> %d / %d", focusXP, xp + pendingXP + focusXP, mx), 0.72, 0.58, 1, 1, 1, 1)
        end
        GameTooltip:AddDoubleLine("Remaining", tostring(math.max(0, mx - xp - pendingXP)), 0.7, 0.7, 0.7, 1, 1, 1)
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("This session (quest related)", 1, 0.82, 0)
        GameTooltip:AddDoubleLine("Quests completed", string.format("%d (%d turned in)", completeCount + login.turnedIn, login.turnedIn), 0.7, 0.7, 0.7, 1, 1, 1)
        GameTooltip:AddDoubleLine("XP earned", tostring(login.xp), 0.7, 0.7, 0.7, 1, 1, 1)
        GameTooltip:AddDoubleLine("Gold earned", CoinText(login.copper), 0.7, 0.7, 0.7, 1, 1, 1)
        GameTooltip:Show()
    end)
    ui.xpBar:SetScript("OnLeave", function() GameTooltip:Hide() end)

    if db.pos then
        ui:ClearAllPoints()
        ui:SetPoint(db.pos[1], UIParent, db.pos[2], db.pos[3], db.pos[4])
    end
    if db.hidden then ui:Hide() end
end

-- all mobs we associate with this quest (matched + Questie-listed)
local function QuestMobNames(s)
    local set, names = {}, {}
    for name in pairs(s.members) do set[name] = true end
    if s.known then for name in pairs(s.known) do set[name] = true end end
    if s.knownObjs then for name in pairs(s.knownObjs) do set[name] = true end end
    for name in pairs(set) do names[#names + 1] = name end
    table.sort(names, function(a, b)
        -- most drops first, then most kills
        local ma, mb = s.mobs[a] or {}, s.mobs[b] or {}
        local ia, ib = ma.items or 0, mb.items or 0
        if ia ~= ib then return ia > ib end
        local da, db_ = ma.drops or 0, mb.drops or 0
        if da ~= db_ then return da > db_ end
        local ka, kb = ma.kills or 0, mb.kills or 0
        if ka ~= kb then return ka > kb end
        return a < b
    end)
    return names
end

local function SuperTrackedId()
    if C_SuperTrack and C_SuperTrack.GetSuperTrackedQuestID then return C_SuperTrack.GetSuperTrackedQuestID() end
    if GetSuperTrackedQuestID then return GetSuperTrackedQuestID() end
end

-- Which quest are we "currently working on"?
--   1. /qmt focus <name> override
--   2. the quest focused in the game's tracker, until another quest sees activity
--   3. the mob you have targeted belongs to a quest in your log
--   4. a quest whose mob you killed / looted in the last 5 minutes (most recent wins)
--   5. the game-tracked quest, then the most recently active one, else first alphabetically
local lastSuper, superAt   -- game-tracker focus, and when it last changed
local function PickQuest(list)
    if db.focus and db.focus ~= "" then
        local f = db.focus:lower()
        for _, s in ipairs(list) do
            if s.title:lower():find(f, 1, true) then return s end
        end
    end
    local now = GetTime()
    -- the quest focused in the game's tracker wins until another quest sees activity
    local st = SuperTrackedId()
    if st ~= lastSuper then
        lastSuper = st
        if st and st ~= 0 then superAt = now end
    end
    if superAt and st and st ~= 0 then
        local focused, otherActive
        for _, s in ipairs(list) do
            if s.questId == st then focused = s
            elseif s.lastActive and s.lastActive > superAt then otherActive = true end
        end
        if focused and not otherActive then return focused end
    end
    -- targeting a mob that belongs to a quest in the log: focus that quest
    local target = UnitExists("target") and not UnitIsPlayer("target") and UName("target")
    if target then
        local hits = {}
        for _, s in ipairs(list) do
            if s.members[target] or (s.known and s.known[target]) then hits[#hits + 1] = s end
        end
        if #hits > 0 then
            local pick = hits[1]
            for _, s in ipairs(hits) do
                if s.lastActive and (not pick.lastActive or s.lastActive > pick.lastActive) then pick = s end
            end
            if not pick.lastActive then
                for _, s in ipairs(hits) do if s.questId == st then pick = s end end
            end
            pick.lastActive = now   -- stays focused for a while after you drop the target
            return pick
        end
    end
    local best
    for _, s in ipairs(list) do
        if s.lastActive and (not best or s.lastActive > best.lastActive) then best = s end
    end
    if best and now - best.lastActive < 300 then return best end
    if st and st ~= 0 then
        for _, s in ipairs(list) do if s.questId == st then return s end end
    end
    if best then return best end
    table.sort(list, function(a, b) return a.title < b.title end)
    return list[1]
end

Refresh = function()
    if not ui or not ui:IsShown() or not db then return end
    local list = ActiveSessions()
    local s = PickQuest(list)
    picked = s

    local rowsShown = 0
    local barColor = (s and s.complete) and PROGRESS_STOPS[4] or ACCENT   -- green once the quest is complete
    ui.cardBar:SetColorTexture(barColor[1], barColor[2], barColor[3], 1)
    local objectiveText = false   -- card shows the quest's objective text instead of kill/drop lines
    if not s then
        ui.title:SetText("Quest Mob Tracker")
        ui.timer:SetText("")
        ui.idle:SetText("")
        for _, t in ipairs(ui.tiles) do t.value:SetText("-"); t.sub:SetText("") end
        ui.cardTitle:SetText("No tracked quest")
        ui.cardSub:SetText("Needs a quest with kill, item or object objectives")
        ui.foot:SetText("")
    else
        local names = QuestMobNames(s)
        local hasItem = false
        for _, o in ipairs(s.objectives) do if o.type == "item" then hasItem = true end end

        local kills, drops, items, xp, copper = 0, 0, 0, 0, 0
        for _, name in ipairs(names) do
            local m = s.mobs[name]
            if m then
                kills = kills + m.kills; drops = drops + m.drops; items = items + m.items
                xp = xp + m.xp; copper = copper + m.copper
            end
        end
        local hours = math.max(s.elapsed, 60) / 3600

        ui.title:SetText(s.title)
        ui.timer:SetText((s.completeAt and "|cff66ff66done|r  " or "") .. FormatTime(s.elapsed))
        ui.idle:SetText((s.started and "idle " or "in log ") .. FormatTime(s.idle))

        local T = ui.tiles
        T[1].value:SetText(kills);  T[1].sub:SetText(string.format("%d / hr", kills / hours))
        -- the quest log's own count is authoritative; ours can miss items picked up before
        -- tracking started or from a source we couldn't see
        local logItems = 0
        for _, o in ipairs(s.objectives) do
            if o.type == "item" then logItems = logItems + (tonumber((o.text or ""):match("^(%d+)/")) or 0) end
        end
        T[2].qmtTracked, T[2].qmtLog = items, logItems
        T[2].value:SetText(hasItem and math.max(items, logItems) or drops)
        T[2].sub:SetText(hasItem and (kills > 0 and string.format("%.0f%% rate", drops / kills * 100) or "items") or "drops")
        T[3].value:SetText(xp)
        T[3].sub:SetText(string.format("%d / hr", xp / hours))
        T[3].qmtXP, T[3].qmtPerHr = xp, xp / hours
        T[4].value:SetText(ShortMoney(copper))
        T[4].sub:SetText(ShortMoney(copper / hours) .. " /hr")
        T[4].qmtCopper, T[4].qmtPerHr = copper, copper / hours

        if hasItem and s.latest then
            ui.cardTitle:SetText(string.format("%s |cffaaaaaax%d|r", s.latest.item, s.latest.count))
            local ago = Ago(s.latest.at)
            ui.cardSub:SetText("Latest drop · " .. s.latest.mob .. (ago ~= "" and (" · " .. ago) or ""))
        elseif not hasItem and s.latestKill then
            ui.cardTitle:SetText(s.latestKill.name)
            local ago = Ago(s.latestKill.at)
            ui.cardSub:SetText("Latest kill" .. (ago ~= "" and (" · " .. ago) or ""))
        else
            if #s.objectives == 0 and s.otherText then
                -- nothing to count: show what the quest asks for instead of "No kills yet"
                local c = s.complete and "|cff66ff66" or "|cffdddddd"
                ui.cardTitle:SetText(c .. s.otherText .. "|r")
                ui.cardSub:SetText(s.destination or "")   -- hand-in location, a small gap below the objective
                objectiveText = true
            else
                ui.cardTitle:SetText(hasItem and "No drops yet" or "No kills yet")
                ui.cardSub:SetText(#names > 0 and "Kill a listed mob below" or "Waiting for a matching mob")
            end
        end

        if scrollTitle ~= s.title then scrollTitle, scrollOffset = s.title, 0 end
        scrollOffset = math.max(0, math.min(scrollOffset, #names - MAX_MOBS))
        for i = 1, MAX_MOBS do
            local r, name = ui.rows[i], names[i + scrollOffset]
            r.srcName = name
            if name then
                local m = s.mobs[name] or { kills = 0, drops = 0, items = 0, xp = 0, copper = 0 }
                local isObj = (s.isObject and s.isObject[name]) or (s.knownObjs and s.knownObjs[name] and not (s.known and s.known[name]))
                r.name:SetText(isObj and (name .. " |cff8f9bb3(object)|r") or name)
                r.cols.kills:SetText(isObj and "-" or m.kills)
                r.cols.drops:SetText(hasItem and m.items or "-")
                r.cols.xp:SetText(m.xp)
                r.cols.gold:SetText(ShortMoney(m.copper))
                local dim = (m.kills == 0 and m.items == 0)
                r.name:SetTextColor(dim and 0.55 or 1, dim and 0.57 or 1, dim and 0.62 or 1)
                r:Show()
                rowsShown = rowsShown + 1
            else
                r:Hide()
            end
        end
        ui.foot:SetText(string.format("%d source(s) known%s", #names, (db.focus and db.focus ~= "") and "  ·  locked (/qmt focus to unlock)" or ""))
        if #names > MAX_MOBS then
            ui.more:SetText(string.format("%d-%d of %d  ·  scroll for more",
                scrollOffset + 1, scrollOffset + MAX_MOBS, #names))
        else
            ui.more:SetText("")
        end
    end
    if not s then for i = 1, MAX_MOBS do ui.rows[i]:Hide() end end

    -- objective list under the card
    local nObj = s and math.min(#s.objectives, MAX_OBJ) or 0
    for i = 1, MAX_OBJ do
        local fs = ui.objFS[i]
        local o = i <= nObj and s.objectives[i]
        if o then
            local text = o.text or o.name
            local have, need = text:match("(%d+)/(%d+)")
            local frac = have and tonumber(need) > 0 and tonumber(have) / tonumber(need)
            fs:SetText((frac and ProgressColor(frac) or "|cffdddddd") .. text .. "|r")
            fs:ClearAllPoints(); fs:SetPoint("TOPLEFT", ui.card, "TOPLEFT", 14, -9 - (i - 1) * OBJ_H)
            fs:Show()
        else
            fs:Hide()
        end
    end
    local objBlock = nObj > 0 and (nObj * OBJ_H + 6) or 0
    local textW = W - PAD * 2 - 24
    ui.cardTitle:SetWidth(objectiveText and textW or 0)
    ui.cardSub:SetWidth(objectiveText and textW or 0)
    if objectiveText then
        ui.cardTitle:SetWordWrap(true); ui.cardSub:SetWordWrap(true)
        local subH = s.destination and (math.ceil(ui.cardSub:GetStringHeight()) + 6) or 0
        objBlock = math.max(-14, math.ceil(ui.cardTitle:GetStringHeight()) + subH + 24 - 46)
    end
    ui.card:SetHeight(46 + objBlock)
    ui.cardTitle:ClearAllPoints(); ui.cardTitle:SetPoint("TOPLEFT", 14, objectiveText and -9 or (-9 - objBlock))
    ui.cardSub:ClearAllPoints()
    if objectiveText then ui.cardSub:SetPoint("TOPLEFT", ui.cardTitle, "BOTTOMLEFT", 0, -6)
    else ui.cardSub:SetPoint("TOPLEFT", 14, -26 - objBlock) end
    local top = -158 - objBlock
    ui.headRow:ClearAllPoints(); ui.headRow:SetPoint("TOPLEFT", PAD, top)
    for i = 1, MAX_MOBS do
        ui.rows[i]:ClearAllPoints(); ui.rows[i]:SetPoint("TOPLEFT", PAD, top - ROW_H * i)
    end

    -- layout below the table
    local y = top - ROW_H * (rowsShown + 1) - 4
    ui.more:ClearAllPoints(); ui.more:SetPoint("TOPLEFT", PAD, y)
    if ui.more:GetText() and ui.more:GetText() ~= "" then y = y - 16 end
    ui.foot:ClearAllPoints(); ui.foot:SetPoint("TOPLEFT", PAD, y - 6)
    y = y - 6 - 14   -- bottom of the footer line
    local height = -y + PAD
    local xp, mx = UnitXP("player"), UnitXPMax("player")
    if xp and mx and mx > 0 then
        local bw = W - PAD * 2
        local curW = bw * math.min(1, xp / mx)
        local pendW = math.min(bw - curW, bw * pendingXP / mx)
        ui.xpBar.cur:SetWidth(math.max(0.001, curW))
        ui.xpBar.pend:SetWidth(math.max(0.001, pendW))
        ui.xpBar.pend:SetShown(pendW > 0.5)
        -- light purple: where the bar would reach if the shown quest were completed too
        local fx = (s and not s.complete and s.rewardXP) or 0
        focusXP = fx
        local focW = math.min(bw - curW - pendW, bw * fx / mx)
        ui.xpBar.focus:SetWidth(math.max(0.001, focW))
        ui.xpBar.focus:SetShown(focW > 0.5)
        -- thin dark divider after each completed quest's share (except the last)
        local x, shown = curW, 0
        for i = 1, #pendingList - 1 do
            x = x + bw * pendingList[i] / mx
            if x < curW + pendW - 1 then
                shown = shown + 1
                local d = ui.xpBar.div[shown]
                if not d then
                    d = ui.xpBar:CreateTexture(nil, "OVERLAY")
                    d:SetColorTexture(0, 0, 0, 0.55)
                    d:SetSize(1, 6)
                    ui.xpBar.div[shown] = d
                end
                d:ClearAllPoints(); d:SetPoint("TOPLEFT", ui.xpBar, "TOPLEFT", x, 0)
                d:Show()
            end
        end
        for i = shown + 1, #ui.xpBar.div do ui.xpBar.div[i]:Hide() end
        ui.xpBar:ClearAllPoints(); ui.xpBar:SetPoint("TOPLEFT", ui, "TOPLEFT", PAD, y - 2)
        ui.xpBar:Show()
        height = height + 2 + 6
    else
        ui.xpBar:Hide()   -- max level
    end
    ui:SetHeight(height)
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local function BuildPatterns()
    lootPatterns = {}
    for _, g in ipairs({ "LOOT_ITEM_SELF", "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF", "LOOT_ITEM_PUSHED_SELF_MULTIPLE" }) do
        if _G[g] then lootPatterns[#lootPatterns + 1] = GP(_G[g], true) end
    end
    xpPattern = GP(COMBATLOG_XPGAIN_FIRSTPERSON or "%s dies, you gain %d experience."):gsub("%$$", "")
    moneyPatterns = {
        gold   = GP(GOLD_AMOUNT or "%d Gold"),
        silver = GP(SILVER_AMOUNT or "%d Silver"),
        copper = GP(COPPER_AMOUNT or "%d Copper"),
    }
    -- the game's own turn-in messages: "<quest> completed.", "Experience gained: N.", "Received <money>."
    questDonePat = GP(ERR_QUEST_COMPLETE_S or "%s completed.", true)
    questExpPat = GP(ERR_QUEST_REWARD_EXP_I or "Experience gained: %d.", true)
    questMoneyPat = GP(ERR_QUEST_REWARD_MONEY_S or "Received %s.", true)
    slainSuffix = (QUEST_MONSTERS_KILLED or "%s slain: %d/%d"):match("%%s(.-):")
end

local engaged, counted = {}, {}   -- guid -> last time we hit it / already counted
local lastKillAt, xpCounted = {}, {}   -- name -> time (kill seen by combat log / by XP message)
local lastXPName, lastXPAt
local lastSource   -- {name=, at=} last mob we killed or looted
local lastObject   -- {name=, at=} last world object (not a unit) we hovered

-- Name of the world object under the cursor (herb, chest, quest object...), if any.
local function WorldObjectName()
    local ok, name = pcall(function()
        if UnitExists("mouseover") then return nil end
        if not GameTooltip:IsShown() or GameTooltip:GetOwner() ~= UIParent then return nil end
        local t = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
        if t and t ~= "" then return t end
    end)
    if ok and name then lastObject = { name = name, at = GetTime() } end
    return ok and name or nil
end

local function RememberUnit(unit)
    if UnitExists(unit) and not UnitIsPlayer(unit) then
        local g, n = UGuid(unit), UName(unit)
        if g and n then guidNames[g] = n end
    end
end

-- Adds a kill of `name` to every active quest; marks the quest active if the mob belongs to it.
local function RecordKill(name, markActive)
    for _, s in ipairs(ActiveSessions()) do
        local m = Stat(s, name)
        m.kills = m.kills + 1
        if s.members[name] or (s.known and s.known[name]) then
            if markActive then s.lastActive = GetTime() end
            s.started = true
            s.latestKill = { name = name, at = time() }
        end
    end
end

local xpUnclaimed = {}   -- name -> {count, at}: XP-message kills whose corpse we haven't seen looted yet
local killVia = {}   -- debug: kills recorded per detection path (combat log / target death / xp message)
local function CountKill(guid, name, via)
    lastSource = { name = name, at = GetTime() }
    if guid then
        if counted[guid] then return end
        counted[guid] = GetTime()
        guidNames[guid] = name
        -- already counted a moment ago from the XP message?
        if xpCounted[name] and GetTime() - xpCounted[name] < 3 then
            xpCounted[name] = nil
            -- this corpse is now identified, so the XP kill's "claim the next loot" marker is spent
            local u = xpUnclaimed[name]
            if u and u.count > 0 then u.count = u.count - 1 end
            return
        end
    end
    lastKillAt[name] = GetTime()
    killVia[via or "?"] = (killVia[via or "?"] or 0) + 1
    if db.traceLoot then print_("kill trace: " .. name .. " counted via " .. tostring(via)) end
    RecordKill(name, true)
end

local function OnCombatLog()
    local getter = CombatLogGetCurrentEventInfo or (C_CombatLog and C_CombatLog.GetCurrentEventInfo)
    if not getter then cleuSeen["no getter"] = 1; return end
    local _, sub, _, srcGUID, _, _, _, destGUID, destName = getter()
    cleuSeen[sub or "?"] = (cleuSeen[sub or "?"] or 0) + 1
    if not destGUID or not destName then return end
    local mine = srcGUID == UGuid("player") or (UGuid("pet") and srcGUID == UGuid("pet"))
    if sub == "PARTY_KILL" then
        guidNames[destGUID] = destName
        if mine then CountKill(destGUID, destName, "combat log PARTY_KILL") end
    elseif sub == "UNIT_DIED" then
        guidNames[destGUID] = destName
        -- fallback: PARTY_KILL doesn't always fire; count mobs we hit in the last minute
        if engaged[destGUID] and GetTime() - engaged[destGUID] < 60 then CountKill(destGUID, destName, "combat log UNIT_DIED") end
    elseif mine and not destGUID:find("^Player") and
        (sub:find("_DAMAGE$") or sub == "SPELL_PERIODIC_DAMAGE" or sub == "SWING_DAMAGE") then
        engaged[destGUID] = GetTime()
    end
end

-- The combat log isn't available to addons on every client, so also watch the
-- target's health: when it dies and the kill was yours, count it.
local function OnTargetHealth(poll)
    if not poll then Dbg("health events") end
    if not UnitExists("target") or UnitIsPlayer("target") or not UnitIsDead("target") then return end
    Dbg("target dead")
    if UnitIsTapDenied and UnitIsTapDenied("target") then Dbg("tap denied"); return end
    local guid, name = UGuid("target"), UName("target")
    if guid and name then
        guidNames[guid] = name
        CountKill(guid, name, poll and "target dead (1s check)" or "target death (UNIT_HEALTH)")
    end
end

-- Nameplate method (same idea as the CountMyKills addon): every visible creature nameplate is a unit token
-- we can ask UnitIsDead / UnitIsTapDenied about, so mobs die-and-count even when they aren't targeted.
local plates = {}   -- unit token ("nameplate3") -> { guid=, name=, counted= }

local function PlateAdded(token)
    if not (UnitExists(token) and not UnitIsPlayer(token)) then return end
    local guid, name = UGuid(token), UName(token)
    if not (guid and name and guid:find("^Creature")) then return end
    guidNames[guid] = name
    plates[token] = { guid = guid, name = name, counted = counted[guid] ~= nil }
    Dbg("plates seen")
end

local function CheckPlate(token)
    local e = plates[token]
    if not e or e.counted then return end
    if counted[e.guid] then e.counted = true; return end
    if not UnitExists(token) or UGuid(token) ~= e.guid or not UnitIsDead(token) then return end
    if UnitIsTapDenied and UnitIsTapDenied(token) then Dbg("plate tap denied"); e.counted = true; return end
    e.counted = true
    CountKill(e.guid, e.name, "nameplate")
end

local function CheckAllPlates()
    for token in pairs(plates) do CheckPlate(token) end
end

local function OnLootOpened()
    local guid
    if GetLootSourceInfo then
        for slot = 1, GetNumLootItems() do
            guid = GetLootSourceInfo(slot)
            if not NotSecret(guid) then guid = nil end
            if guid then break end
        end
    end
    lastLoot.token = lastLoot.token + 1
    Dbg("loot opened"); Dbg("last loot guid", tostring(guid))
    lastLoot.guid = guid
    lastLoot.isObject = false
    local name = guid and guidNames[guid]
    if not name then
        local obj = WorldObjectName()
        if obj then name = obj; lastLoot.isObject = true end
    end
    name = name or UName("target")
        or (lastXPName and lastXPAt and GetTime() - lastXPAt < 30 and lastXPName) or nil
    lastLoot.name = name
    -- Fallback kill: looting a creature corpse we never counted (no combat log here, and no XP message
    -- for grey mobs). Only when the name is certain: from the GUID itself or the target holding it.
    local claim = guid and name and xpUnclaimed[name]
    if claim and claim.count > 0 and GetTime() - claim.at <= 120 and not counted[guid] then
        claim.count = claim.count - 1
        counted[guid] = GetTime()   -- this corpse was already counted from its XP message
    elseif guid and guid:find("^Creature") and not counted[guid] then
        local kname = guidNames[guid] or (UGuid("target") == guid and UName("target")) or nil
        if kname then pcall(CountKill, guid, kname, "loot") else Dbg("loot: corpse name unknown") end
    elseif guid and counted[guid] then Dbg("loot: already counted")
    elseif guid then Dbg("loot: not a creature guid") end
    if name then lastLootSrc = { name = name, at = GetTime() } end
    if name and not lastLoot.isObject then lastSource = { name = name, at = GetTime() } end
end

local function OnLootClosed()
    local t = lastLoot.token
    C_Timer.After(1.5, function()
        if lastLoot.token == t then lastLoot.guid, lastLoot.name, lastLoot.isObject = nil, nil, nil end
    end)
end

local function OnChatLoot(msg)
    for _, p in ipairs(lootPatterns) do
        local link, count = msg:match(p)
        if link then
            local itemName = link:match("%[(.-)%]")
            count = tonumber(count) or 1
            if db.traceLoot then
                print_(string.format("loot trace: item=%s lootName=%s lootGUID=%s lastSource=%s (%ss ago) lastXP=%s target=%s",
                    tostring(itemName), tostring(lastLoot.name), tostring(lastLoot.guid),
                    tostring(lastSource and lastSource.name),
                    lastSource and string.format("%.0f", GetTime() - lastSource.at) or "-",
                    tostring(lastXPName), tostring(UName("target"))))
            end
            local src, isObj = lastLoot.name, lastLoot.isObject
            if not src then
                local obj = WorldObjectName()
                if obj then
                    src, isObj = obj, true
                elseif lastObject and GetTime() - lastObject.at < 5
                    and not (lastSource and lastSource.at > lastObject.at) then
                    src, isObj = lastObject.name, true
                end
            end
            src = src or (lastSource and GetTime() - lastSource.at < 90 and lastSource.name) or "Unknown source"
            for _, s in ipairs(ActiveSessions()) do
                local matched = false
                for _, o in ipairs(s.objectives) do
                    if o.type == "item" and o.name == itemName then
                        local src, isObj = src, isObj
                        -- Questie says this item only comes from world objects: use that
                        if not isObj and s.knownObjs and not s.known then
                            local only, n = nil, 0
                            for oname in pairs(s.knownObjs) do only = oname; n = n + 1 end
                            if n == 1 then src, isObj = only, true end
                        end
                        if s.knownObjs and s.knownObjs[src] then isObj = true end
                        s.members[src] = true
                        Adopt(s, src)
                        if isObj then s.isObject[src] = true end
                        s.lastActive = GetTime()
                        s.started = true
                        s.latest = { item = itemName, count = count, mob = src, at = time() }
                        local m = Mob(s, src)
                        m.items = m.items + count
                        if lastLoot.guid then
                            if not s.dropGUIDs[lastLoot.guid] then
                                s.dropGUIDs[lastLoot.guid] = true
                                m.drops = m.drops + 1
                            end
                        else
                            m.drops = m.drops + 1
                        end
                        AddLoot(m, itemName, link, count)
                        matched = true
                        break
                    end
                end
                -- any other item from one of this quest's mobs goes in the tooltip list too
                if not matched and Related(s, src) then
                    AddLoot(Mob(s, src), itemName, link, count)
                end
            end
            return
        end
    end
end

local function OnChatXP(msg)
    local name, amount = msg:match(xpPattern)
    amount = tonumber(amount)
    if not (name and amount) then return end
    lastXPName, lastXPAt = name, GetTime()
    lastSource = { name = name, at = GetTime() }
    -- kill count from the XP message, unless a death check already counted this kill a moment ago
    if not lastKillAt[name] or GetTime() - lastKillAt[name] > 3 then
        do   -- remember which corpse this was, so looting it later isn't counted as another kill
            local tg = UGuid("target")
            if tg and UName("target") == name then
                counted[tg] = GetTime(); guidNames[tg] = name
            else   -- corpse unknown: the next loot of this name claims this kill instead of counting again
                local u = xpUnclaimed[name]
                if not u or GetTime() - u.at > 120 then u = { count = 0 }; xpUnclaimed[name] = u end
                u.count, u.at = u.count + 1, GetTime()
            end
        end
        xpCounted[name] = GetTime()
        killVia["xp message"] = (killVia["xp message"] or 0) + 1
        if db.traceLoot then print_("kill trace: " .. name .. " counted via xp message (CHAT_MSG_COMBAT_XP_GAIN)") end
        RecordKill(name, false)
    end
    local related = false
    for _, s in ipairs(ActiveSessions()) do
        if Related(s, name) then related = true end
        local m = Stat(s, name)
        m.xp = m.xp + amount
        s.totalXP = s.totalXP + amount
    end
    if related then login.xp = login.xp + amount end
end

local function MoneyIn(text)
    local g = tonumber(text:match(moneyPatterns.gold)) or 0
    local sv = tonumber(text:match(moneyPatterns.silver)) or 0
    local c = tonumber(text:match(moneyPatterns.copper)) or 0
    return g * 10000 + sv * 100 + c
end

-- Quest turn-in messages. Returns true when the line was one of them. Quests that only finish at the
-- hand-in aren't "complete" in the log beforehand, so the log can't tell us; the messages can.
local lastQuestMoney = { amount = 0, at = -10 }
local function OnQuestMsg(msg)
    if not (questDonePat and msg) then return false end
    local title = msg:match(questDonePat)
    if title then
        CountTurnIn(title, "completed message")
        return true
    end
    local xp = tonumber(msg:match(questExpPat))
    if xp then
        QuestRewardSeen()
        login.xp = login.xp + xp
        Dbg("quest xp seen", (dbg["quest xp seen"] or 0) + xp)
        if db.traceLoot then print_("turn-in trace: +" .. xp .. " xp") end
        return true
    end
    local money = msg:match(questMoneyPat)
    if money then
        local total = MoneyIn(money)
        if total > 0 then QuestRewardSeen() end
        -- the same line can reach both chat events; count it once
        if total > 0 and not (lastQuestMoney.amount == total and GetTime() - lastQuestMoney.at < 1) then
            lastQuestMoney.amount, lastQuestMoney.at = total, GetTime()
            login.copper = login.copper + total
            if db.traceLoot then print_("turn-in trace: +" .. total .. " copper") end
        end
        return true
    end
    return false
end

local function OnChatMoney(msg)
    if OnQuestMsg(msg) then return end   -- quest reward money is not mob gold
    local g = tonumber(msg:match(moneyPatterns.gold)) or 0
    local sv = tonumber(msg:match(moneyPatterns.silver)) or 0
    local c = tonumber(msg:match(moneyPatterns.copper)) or 0
    local total = g * 10000 + sv * 100 + c
    if total <= 0 then return end
    -- The money line can arrive a second or more after the loot window closed (and lastLoot is
    -- cleared), so fall back to the last corpse we opened.
    local src = lastLoot.name
    if not src and lastLootSrc and GetTime() - lastLootSrc.at < 10 then src = lastLootSrc.name end
    if db.traceLoot then
        print_(string.format("money trace: %d copper, source=%s (lastLoot=%s)", total, tostring(src), tostring(lastLoot.name)))
    end
    local related = false
    for _, s in ipairs(ActiveSessions()) do
        s.totalCopper = s.totalCopper + total
        if src then
            if Related(s, src) then related = true end
            local m = Stat(s, src)
            m.copper = m.copper + total
        end
    end
    if related then login.copper = login.copper + total end
end


-- Name of a quest by id: from the last scan, else Questie's database (the quest may never have been in the log).
local function TitleFor(questId)
    if not questId then return nil end
    if titleById[questId] then return titleById[questId] end
    local name
    if QuestieLoader and QuestieLoader.ImportModule then
        local ok, DB = pcall(function() return QuestieLoader:ImportModule("QuestieDB") end)
        if ok and DB and DB.QueryQuestSingle then name = Try(DB.QueryQuestSingle, questId, "name") end
    end
    return name or ("quest " .. tostring(questId))
end

-- Backup signal: Questie's public API reports turn-ins and abandons separately and already copes with this
-- client's late/missing QUEST_TURNED_IN.
local questieHooked = false
local function HookQuestie()
    if questieHooked then return end
    local api = Questie and Questie.API
    if not (api and type(api.RegisterForQuestUpdates) == "function") then return end
    questieHooked = true
    local reasons = api.Enums and api.Enums.QuestUpdateTriggerReason
    local turnedIn = reasons and reasons.QUEST_TURNED_IN or 3
    api.RegisterForQuestUpdates(function(questId, _, why)
        if why == turnedIn then CountTurnIn(TitleFor(questId), "Questie API") end
    end)
end

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if (...) ~= ADDON then return end
        QuestMobTrackerDB = QuestMobTrackerDB or {}
        db = QuestMobTrackerDB
        db.quests = db.quests or {}
        db.history = db.history or {}
        -- "Next quest" used to save a temporary focus; it must not turn into a permanent lock
        if db.focusSoft then db.focus = nil end
        db.focusSoft, db.focusAt = nil, nil
        BuildPatterns()
        BuildUI()
    elseif not db then
        return
    elseif event == "QUEST_TURNED_IN" then
        local questId = ...
        pcall(function() CountTurnIn(TitleFor(questId), "QUEST_TURNED_IN event") end)
    elseif event == "PLAYER_LOGIN" or event == "QUEST_LOG_UPDATE" or event == "QUEST_ACCEPTED"
        or event == "UNIT_QUEST_LOG_CHANGED" then
        pcall(HookQuestie)
        local ok, err = pcall(ScanQuests)
        if not ok and not scanErrShown then scanErrShown = true; print_("Scan error: " .. tostring(err)) end
    elseif event == "PLAYER_TARGET_CHANGED" then
        pcall(RememberUnit, "target")
        Refresh()
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        pcall(RememberUnit, "mouseover")
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local ok, err = pcall(OnCombatLog)
        if not ok then cleuSeen["ERR " .. tostring(err):sub(1, 80)] = 1 end
    elseif event == "UNIT_HEALTH" then
        local unit = ...
        if unit == "target" then pcall(OnTargetHealth)
        elseif plates[unit] then pcall(CheckPlate, unit) end
    elseif event == "NAME_PLATE_UNIT_ADDED" then
        pcall(PlateAdded, (...))
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        local token = ...
        pcall(CheckPlate, token)   -- last look: it may have died just as the plate went away
        plates[token] = nil
    elseif event == "LOOT_OPENED" or event == "LOOT_READY" then
        OnLootOpened()   -- with auto-loot LOOT_READY comes first and the window may close before LOOT_OPENED
    elseif event == "LOOT_CLOSED" then
        OnLootClosed()
    elseif event == "CHAT_MSG_LOOT" then
        OnChatLoot((...))
    elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
        OnChatXP((...))
    elseif event == "CHAT_MSG_MONEY" then
        OnChatMoney((...))
    elseif event == "CHAT_MSG_SYSTEM" then
        pcall(OnQuestMsg, (...))
    end
end)

-- diagnostic: the client blocks a protected call without saying which; remember what we were registering
local registering
local diag = CreateFrame("Frame")
pcall(diag.RegisterEvent, diag, "ADDON_ACTION_FORBIDDEN")
diag:SetScript("OnEvent", function(_, _, addon, func)
    if addon == ADDON then print_("Blocked call " .. tostring(func) .. " while registering " .. tostring(registering)) end
end)

-- One call per event on purpose: a blocked (protected) call is reported with its line number,
-- so the line tells us which event the client refused.
local function Registered(e, ok, err)
    registering = nil
    -- a protected event is blocked (and logged by BugGrabber) rather than raising an error, so check
    if not ok then print_("Could not register " .. e .. ": " .. tostring(err))
    elseif frame.IsEventRegistered and not frame:IsEventRegistered(e) then print_("Event blocked by the client: " .. e) end
end

registering = "ADDON_LOADED"; Registered("ADDON_LOADED", pcall(frame.RegisterEvent, frame, "ADDON_LOADED"))
registering = "PLAYER_LOGIN"; Registered("PLAYER_LOGIN", pcall(frame.RegisterEvent, frame, "PLAYER_LOGIN"))
registering = "QUEST_LOG_UPDATE"; Registered("QUEST_LOG_UPDATE", pcall(frame.RegisterEvent, frame, "QUEST_LOG_UPDATE"))
registering = "QUEST_ACCEPTED"; Registered("QUEST_ACCEPTED", pcall(frame.RegisterEvent, frame, "QUEST_ACCEPTED"))
registering = "PLAYER_TARGET_CHANGED"; Registered("PLAYER_TARGET_CHANGED", pcall(frame.RegisterEvent, frame, "PLAYER_TARGET_CHANGED"))
registering = "UPDATE_MOUSEOVER_UNIT"; Registered("UPDATE_MOUSEOVER_UNIT", pcall(frame.RegisterEvent, frame, "UPDATE_MOUSEOVER_UNIT"))
registering = "UNIT_QUEST_LOG_CHANGED"; Registered("UNIT_QUEST_LOG_CHANGED", pcall(frame.RegisterEvent, frame, "UNIT_QUEST_LOG_CHANGED"))
-- COMBAT_LOG_EVENT_UNFILTERED is not registered: this client blocks it for addons (nothing is ever delivered)
registering = "NAME_PLATE_UNIT_ADDED"; Registered("NAME_PLATE_UNIT_ADDED", pcall(frame.RegisterEvent, frame, "NAME_PLATE_UNIT_ADDED"))
registering = "NAME_PLATE_UNIT_REMOVED"; Registered("NAME_PLATE_UNIT_REMOVED", pcall(frame.RegisterEvent, frame, "NAME_PLATE_UNIT_REMOVED"))
registering = "UNIT_HEALTH"; Registered("UNIT_HEALTH", pcall(frame.RegisterEvent, frame, "UNIT_HEALTH"))
registering = "LOOT_READY"; Registered("LOOT_READY", pcall(frame.RegisterEvent, frame, "LOOT_READY"))
registering = "LOOT_OPENED"; Registered("LOOT_OPENED", pcall(frame.RegisterEvent, frame, "LOOT_OPENED"))
registering = "LOOT_CLOSED"; Registered("LOOT_CLOSED", pcall(frame.RegisterEvent, frame, "LOOT_CLOSED"))
registering = "CHAT_MSG_LOOT"; Registered("CHAT_MSG_LOOT", pcall(frame.RegisterEvent, frame, "CHAT_MSG_LOOT"))
registering = "CHAT_MSG_COMBAT_XP_GAIN"; Registered("CHAT_MSG_COMBAT_XP_GAIN", pcall(frame.RegisterEvent, frame, "CHAT_MSG_COMBAT_XP_GAIN"))
registering = "QUEST_TURNED_IN"; Registered("QUEST_TURNED_IN", pcall(frame.RegisterEvent, frame, "QUEST_TURNED_IN"))
registering = "CHAT_MSG_SYSTEM"; Registered("CHAT_MSG_SYSTEM", pcall(frame.RegisterEvent, frame, "CHAT_MSG_SYSTEM"))
registering = "CHAT_MSG_MONEY"; Registered("CHAT_MSG_MONEY", pcall(frame.RegisterEvent, frame, "CHAT_MSG_MONEY"))

-- per-session lookup tables would otherwise grow with every mob ever seen
local function PruneCaches(now)
    for guid, t in pairs(counted) do if now - t > 600 then counted[guid] = nil end end
    for guid, t in pairs(engaged) do if now - t > 600 then engaged[guid] = nil end end
    local n = 0
    for _ in pairs(guidNames) do n = n + 1 end
    if n > 1000 then wipe(guidNames) end
    for title, p in pairs(pending) do   -- unmatched-mob holding area: keep it small
        local c = 0
        for _ in pairs(p) do c = c + 1 end
        if c > 200 then wipe(p) end
    end
end

local acc, sincePrune = 0, 0
frame:SetScript("OnUpdate", function(_, dt)
    if not db then return end
    acc = acc + dt
    if acc >= 1 then
        local now, inCombat = GetTime(), UnitAffectingCombat("player")
        sincePrune = sincePrune + acc
        if sincePrune >= 120 then sincePrune = 0; PruneCaches(now) end
        -- UNIT_HEALTH is sparse on this client, so also look at the target once a second
        local tg = UnitExists("target") and UGuid("target")
        if tg and not counted[tg] then pcall(OnTargetHealth, true) end
        pcall(CheckAllPlates)
        for _, s in ipairs(ActiveSessions()) do
            s.idle = s.idle or 0
            if not s.completeAt then   -- timers freeze once the objectives are done
                local working = s.started and (inCombat or (s.lastActive and now - s.lastActive < IDLE_AFTER))
                if working then s.elapsed = s.elapsed + acc else s.idle = s.idle + acc end
            end
        end
        acc = 0
        Refresh()
    end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
SLASH_QMT1 = "/qmt"
SlashCmdList["QMT"] = function(input)
    local cmd = (input or ""):match("^(%S*)"):lower()
    if cmd == "reset" then
        db.quests = {}
        ScanQuests()
        print_("All sessions reset.")
    elseif cmd == "show" then
        db.hidden = false; ui:Show()
    elseif cmd == "hide" then
        db.hidden = true; ui:Hide()
    elseif cmd == "debug" then
        Debug()
    elseif cmd == "kills" then
        local t, k = {}, {}
        print_("Quest Mob Tracker v" .. Version())
        for n, v in pairs(cleuSeen) do t[#t + 1] = n .. "=" .. v end
        for n, v in pairs(killVia) do k[#k + 1] = n .. "=" .. v end
        table.sort(t); table.sort(k)
        print_("Combat log events received: " .. (#t > 0 and table.concat(t, ", ") or "none"))
        print_("Kills counted by: " .. (#k > 0 and table.concat(k, ", ") or "nothing yet"))
        local d = {}
        for n, v in pairs(dbg) do d[#d + 1] = n .. "=" .. tostring(v) end
        table.sort(d)
        print_("Detail: " .. (#d > 0 and table.concat(d, ", ") or "no events yet"))
    elseif cmd == "trace" then
        db.traceLoot = not db.traceLoot
        print_("Trace " .. (db.traceLoot and "ON: prints each kill (and the path that counted it) and each money line." or "off"))
    elseif cmd == "scale" then
        local v = tonumber((input or ""):match("^%S+%s+(%S+)"))
        if v and v >= 0.4 and v <= 2 then
            db.scale = v; ui:SetScale(v)
        else
            print_("Usage: /qmt scale 0.4-2 (now " .. (db.scale or 0.85) .. ")")
        end
    elseif cmd == "alpha" then
        local v = tonumber((input or ""):match("^%S+%s+(%S+)"))
        if v and v >= 0 and v <= 1 then
            db.alpha = v
            ui:SetBackdropColor(0.06, 0.07, 0.09, v)
            ui:SetBackdropBorderColor(0, 0, 0, math.min(1, v + 0.2))
        else
            print_("Usage: /qmt alpha 0-1 (now " .. (db.alpha or 0.6) .. ")")
        end
    elseif cmd == "focus" then
        local name = (input or ""):match("^%S+%s+(.+)$")
        db.focus = name
        print_(name and ("Locked on quest matching '" .. name .. "'.") or "Auto-picking the quest you're working on.")
    elseif cmd == "history" then
        if #db.history == 0 then print_("No finished quests yet.") end
        for _, s in ipairs(db.history) do
            local k, x, c = 0, 0, 0
            for name in pairs(s.members) do
                local m = s.mobs[name]
                if m then k = k + m.kills; x = x + m.xp; c = c + m.copper end
            end
            print_(string.format("%s: %s, %d kills, %d xp, %s", s.title, FormatTime(s.elapsed), k, x, Money(c)))
        end
    else
        print_("/qmt show | hide | focus [quest] | scale <n> | alpha <n> | reset | history | kills | debug | trace")
    end
    Refresh()
end
