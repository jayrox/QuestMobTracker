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
local lootPatterns, xpPattern, moneyPatterns, slainSuffix

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
                out[#out + 1] = q
            end
        end
        if oldSel and SelectQuestLogEntry then SelectQuestLogEntry(oldSel) end
    end
    return out
end

local function ScanQuests()
    local seen = {}
    for _, q in ipairs(ReadQuestLog()) do
        local title = q.title
        local objs = {}
        for _, o in ipairs(q.objs) do
            if o.type == "monster" or o.type == "item" then
                local name = ParseObjective(o.text, o.type)
                if name then objs[#objs + 1] = { type = o.type, name = name, text = o.text } end
            end
        end
        if #objs > 0 then
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
            print_("'" .. title .. "' left your log. Final time " .. FormatTime(s.elapsed) .. ".")
        end
    end
end

local function Debug()
    local t = {}
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
local W, PAD, MAX_MOBS, MAX_OBJ = 372, 12, 8, 5
local OBJ_H = 14
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
    if d < 60 then return "just now" end
    if d < 3600 then return math.floor(d / 60) .. "m ago" end
    return math.floor(d / 3600) .. "h ago"
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

local function FlatButton(parent, label, w, onclick)
    local b = CreateFrame("Button", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    b:SetSize(w, 22)
    b:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
    b:SetBackdropColor(1, 1, 1, 0.06)
    b:SetBackdropBorderColor(1, 1, 1, 0.12)
    local t = Text(b, "GameFontHighlightSmall", "CENTER")
    t:SetAllPoints()
    t:SetText(label)
    b:SetScript("OnEnter", function(self) self:SetBackdropColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.25) end)
    b:SetScript("OnLeave", function(self) self:SetBackdropColor(1, 1, 1, 0.06) end)
    b:SetScript("OnClick", onclick)
    return b
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

    -- latest find card
    ui.card = Panel(ui, W - PAD * 2, 46, 0.08)
    ui.card:SetPoint("TOPLEFT", PAD, -104)
    local bar = ui.card:CreateTexture(nil, "ARTWORK")
    bar:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 1)
    bar:SetPoint("TOPLEFT"); bar:SetPoint("BOTTOMLEFT"); bar:SetWidth(3)
    ui.cardTitle = Text(ui.card, "GameFontHighlight"); ui.cardTitle:SetPoint("TOPLEFT", 14, -9)
    ui.cardSub = Text(ui.card, "GameFontNormalSmall"); ui.cardSub:SetPoint("TOPLEFT", 14, -26)
    ui.cardSub:SetTextColor(0.62, 0.64, 0.7)

    -- objective list (between the card and the table; positioned in Refresh)
    ui.objFS = {}
    for i = 1, MAX_OBJ do
        local fs = Text(ui, "GameFontHighlightSmall")
        fs:SetWidth(W - PAD * 2 - 4)
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
        r:SetSize(W - PAD * 2, ROW_H)
        r:SetPoint("TOPLEFT", PAD, -158 - ROW_H * i)
        Cols(r, false)
        ui.rows[i] = r
    end
    ui.more = Text(ui, "GameFontNormalSmall"); ui.more:SetTextColor(0.5, 0.52, 0.58)

    -- footer
    ui.foot = Text(ui, "GameFontNormalSmall")
    ui.foot:SetTextColor(0.5, 0.52, 0.58)
    ui.btnAuto = FlatButton(ui, "Auto", 70, function() db.focus, db.focusSoft, db.focusAt = nil, nil, nil; Refresh() end)
    ui.btnNext = FlatButton(ui, "Next quest", 90, function()
        local list = ActiveSessions()
        table.sort(list, function(a, b) return a.title < b.title end)
        if #list == 0 then return end
        local idx = 0
        for i, s in ipairs(list) do if s == picked then idx = i end end
        db.focus = list[(idx % #list) + 1].title
        db.focusSoft, db.focusAt = true, GetTime()   -- just a peek: expires after 20s or when another quest gets activity
        Refresh()
    end)
    ui.btnReset = FlatButton(ui, "Reset quest", 90, function()
        if picked then
            db.quests[picked.title] = nil
            ScanQuests()
            Refresh()
        end
    end)

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
        local ka = s.mobs[a] and s.mobs[a].kills or 0
        local kb = s.mobs[b] and s.mobs[b].kills or 0
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
--   2. the mob you have targeted belongs to a quest in your log
--   3. a quest whose mob you killed / looted in the last 5 minutes (most recent wins)
--   3. the quest you selected in the game's tracker
--   4. most recently active quest this session, else first alphabetically
local lastSuper, superAt   -- game-tracker focus, and when it last changed
local function PickQuest(list)
    if db.focus and db.focus ~= "" then
        local f = db.focus:lower()
        -- a focus picked with "Next quest" is soft: activity on another quest releases it
        if db.focusSoft and db.focusAt then
            if GetTime() - db.focusAt > 20 or GetTime() < db.focusAt then
                db.focus, db.focusSoft, db.focusAt = nil, nil, nil   -- peek expired
            end
            for _, s in ipairs(list) do
                if s.lastActive and s.lastActive > db.focusAt and not s.title:lower():find(f, 1, true) then
                    db.focus, db.focusSoft, db.focusAt = nil, nil, nil
                    break
                end
            end
        end
    end
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
    local target = UnitExists("target") and not UnitIsPlayer("target") and UnitName("target")
    if target then
        local hits = {}
        for _, s in ipairs(list) do
            if s.members[target] or (s.known and s.known[target]) then hits[#hits + 1] = s end
        end
        if #hits > 0 then
            local pick, st = hits[1], SuperTrackedId()
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
    local st = SuperTrackedId()
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
    if not s then
        ui.title:SetText("Quest Mob Tracker")
        ui.timer:SetText("")
        ui.idle:SetText("")
        for _, t in ipairs(ui.tiles) do t.value:SetText("-"); t.sub:SetText("") end
        ui.cardTitle:SetText("No tracked quest")
        ui.cardSub:SetText("Needs a quest with kill or item objectives")
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
        T[2].value:SetText(hasItem and items or drops)
        T[2].sub:SetText(hasItem and (kills > 0 and string.format("%.0f%% rate", drops / kills * 100) or "items") or "drops")
        T[3].value:SetText(xp);     T[3].sub:SetText(string.format("%d / hr", xp / hours))
        T[4].value:SetText(ShortMoney(copper)); T[4].sub:SetText(ShortMoney(copper / hours) .. " /hr")

        if hasItem and s.latest then
            ui.cardTitle:SetText(string.format("%s |cffaaaaaax%d|r", s.latest.item, s.latest.count))
            ui.cardSub:SetText(string.format("Latest drop · %s · %s", s.latest.mob, Ago(s.latest.at)))
        elseif not hasItem and s.latestKill then
            ui.cardTitle:SetText(s.latestKill.name)
            ui.cardSub:SetText("Latest kill · " .. Ago(s.latestKill.at))
        else
            ui.cardTitle:SetText(hasItem and "No drops yet" or "No kills yet")
            ui.cardSub:SetText(#names > 0 and "Kill a listed mob below" or "Waiting for a matching mob")
        end

        for i = 1, MAX_MOBS do
            local r, name = ui.rows[i], names[i]
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
        ui.foot:SetText(string.format("%d source(s) known%s", #names, (db.focus and not db.focusSoft) and "  ·  locked" or ""))
        if #names > MAX_MOBS then
            ui.more:SetText(string.format("+%d more", #names - MAX_MOBS))
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
            local done = have and tonumber(have) >= tonumber(need)
            fs:SetText((done and "|cff66ff66" or "|cffdddddd") .. text .. "|r")
            fs:ClearAllPoints(); fs:SetPoint("TOPLEFT", PAD + 2, -156 - (i - 1) * OBJ_H)
            fs:Show()
        else
            fs:Hide()
        end
    end
    local top = -158 - (nObj > 0 and nObj * OBJ_H + 6 or 0)
    ui.headRow:ClearAllPoints(); ui.headRow:SetPoint("TOPLEFT", PAD, top)
    for i = 1, MAX_MOBS do
        ui.rows[i]:ClearAllPoints(); ui.rows[i]:SetPoint("TOPLEFT", PAD, top - ROW_H * i)
    end

    -- layout below the table
    local y = top - ROW_H * (rowsShown + 1) - 4
    ui.more:ClearAllPoints(); ui.more:SetPoint("TOPLEFT", PAD, y)
    if ui.more:GetText() and ui.more:GetText() ~= "" then y = y - 16 end
    ui.foot:ClearAllPoints(); ui.foot:SetPoint("TOPLEFT", PAD, y - 6)
    y = y - 26
    ui.btnAuto:ClearAllPoints();  ui.btnAuto:SetPoint("TOPRIGHT", ui, "TOPRIGHT", -PAD - 90 * 2 - 8, y)
    ui.btnNext:ClearAllPoints();  ui.btnNext:SetPoint("TOPRIGHT", ui, "TOPRIGHT", -PAD - 90 - 4, y)
    ui.btnReset:ClearAllPoints(); ui.btnReset:SetPoint("TOPRIGHT", ui, "TOPRIGHT", -PAD, y)
    ui:SetHeight(-y + 22 + PAD)
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
        local g, n = UnitGUID(unit), UnitName(unit)
        if g and n then guidNames[g] = n end
    end
end

local function CountKill(guid, name)
    lastSource = { name = name, at = GetTime() }
    if guid then
        if counted[guid] then return end
        counted[guid] = true
        guidNames[guid] = name
        -- already counted a moment ago from the XP message?
        if xpCounted[name] and GetTime() - xpCounted[name] < 3 then
            xpCounted[name] = nil
            return
        end
    end
    lastKillAt[name] = GetTime()
    lastSource = { name = name, at = GetTime() }
    for _, s in ipairs(ActiveSessions()) do
        local m = Mob(s, name)
        m.kills = m.kills + 1
        if s.members[name] or (s.known and s.known[name]) then
            s.lastActive = GetTime(); s.started = true
            s.latestKill = { name = name, at = time() }
        end
    end
end

local function OnCombatLog()
    local getter = CombatLogGetCurrentEventInfo or (C_CombatLog and C_CombatLog.GetCurrentEventInfo)
    if not getter then cleuSeen["no getter"] = 1; return end
    local _, sub, _, srcGUID, _, _, _, destGUID, destName = getter()
    cleuSeen[sub or "?"] = (cleuSeen[sub or "?"] or 0) + 1
    if not destGUID or not destName then return end
    local mine = srcGUID == UnitGUID("player") or (UnitGUID("pet") and srcGUID == UnitGUID("pet"))
    if sub == "PARTY_KILL" then
        guidNames[destGUID] = destName
        if mine then CountKill(destGUID, destName) end
    elseif sub == "UNIT_DIED" then
        guidNames[destGUID] = destName
        -- fallback: PARTY_KILL doesn't always fire; count mobs we hit in the last minute
        if engaged[destGUID] and GetTime() - engaged[destGUID] < 60 then CountKill(destGUID, destName) end
    elseif mine and not destGUID:find("^Player") and
        (sub:find("_DAMAGE$") or sub == "SPELL_PERIODIC_DAMAGE" or sub == "SWING_DAMAGE") then
        engaged[destGUID] = GetTime()
    end
end

-- The combat log isn't available to addons on every client, so also watch the
-- target's health: when it dies and the kill was yours, count it.
local function OnTargetHealth()
    if not UnitExists("target") or UnitIsPlayer("target") or not UnitIsDead("target") then return end
    if UnitIsTapDenied and UnitIsTapDenied("target") then return end
    local guid, name = UnitGUID("target"), UnitName("target")
    if guid and name then
        guidNames[guid] = name
        CountKill(guid, name)
    end
end

local function OnLootOpened()
    local guid
    if GetLootSourceInfo then
        for slot = 1, GetNumLootItems() do
            guid = GetLootSourceInfo(slot)
            if guid then break end
        end
    end
    lastLoot.token = lastLoot.token + 1
    lastLoot.guid = guid
    lastLoot.isObject = false
    local name = guid and guidNames[guid]
    if not name then
        local obj = WorldObjectName()
        if obj then name = obj; lastLoot.isObject = true end
    end
    name = name or UnitName("target")
        or (lastXPName and lastXPAt and GetTime() - lastXPAt < 30 and lastXPName) or nil
    lastLoot.name = name
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
                    tostring(lastXPName), tostring(UnitName("target"))))
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
                        break
                    end
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
    -- fallback kill count when the combat log didn't report this kill
    if not lastKillAt[name] or GetTime() - lastKillAt[name] > 3 then
        xpCounted[name] = GetTime()
        for _, s in ipairs(ActiveSessions()) do
            Mob(s, name).kills = Mob(s, name).kills + 1
            if s.members[name] or (s.known and s.known[name]) then
                s.started = true
                s.latestKill = { name = name, at = time() }
            end
        end
    end
    for _, s in ipairs(ActiveSessions()) do
        Mob(s, name).xp = Mob(s, name).xp + amount
        s.totalXP = s.totalXP + amount
    end
end

local function OnChatMoney(msg)
    local g = tonumber(msg:match(moneyPatterns.gold)) or 0
    local sv = tonumber(msg:match(moneyPatterns.silver)) or 0
    local c = tonumber(msg:match(moneyPatterns.copper)) or 0
    local total = g * 10000 + sv * 100 + c
    if total <= 0 then return end
    for _, s in ipairs(ActiveSessions()) do
        s.totalCopper = s.totalCopper + total
        if lastLoot.name then Mob(s, lastLoot.name).copper = Mob(s, lastLoot.name).copper + total end
    end
end

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "ADDON_LOADED" then
        if (...) ~= ADDON then return end
        QuestMobTrackerDB = QuestMobTrackerDB or {}
        db = QuestMobTrackerDB
        db.quests = db.quests or {}
        db.history = db.history or {}
        BuildPatterns()
        BuildUI()
    elseif not db then
        return
    elseif event == "PLAYER_LOGIN" or event == "QUEST_LOG_UPDATE" or event == "QUEST_ACCEPTED"
        or event == "UNIT_QUEST_LOG_CHANGED" then
        local ok, err = pcall(ScanQuests)
        if not ok and not QMT_errShown then QMT_errShown = true; print_("Scan error: " .. tostring(err)) end
    elseif event == "PLAYER_TARGET_CHANGED" then
        pcall(RememberUnit, "target")
        Refresh()
    elseif event == "UPDATE_MOUSEOVER_UNIT" then
        pcall(RememberUnit, "mouseover")
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local ok, err = pcall(OnCombatLog)
        if not ok then cleuSeen["ERR " .. tostring(err):sub(1, 80)] = 1 end
    elseif event == "UNIT_HEALTH" then
        if (...) == "target" then pcall(OnTargetHealth) end
    elseif event == "LOOT_OPENED" then
        OnLootOpened()
    elseif event == "LOOT_CLOSED" then
        OnLootClosed()
    elseif event == "CHAT_MSG_LOOT" then
        OnChatLoot((...))
    elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
        OnChatXP((...))
    elseif event == "CHAT_MSG_MONEY" then
        OnChatMoney((...))
    end
end)

for _, e in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "QUEST_LOG_UPDATE", "QUEST_ACCEPTED", "PLAYER_TARGET_CHANGED", "UPDATE_MOUSEOVER_UNIT",
    "UNIT_QUEST_LOG_CHANGED", "COMBAT_LOG_EVENT_UNFILTERED", "UNIT_HEALTH", "LOOT_OPENED", "LOOT_CLOSED",
    "CHAT_MSG_LOOT", "CHAT_MSG_COMBAT_XP_GAIN", "CHAT_MSG_MONEY" }) do
    local ok, err = pcall(frame.RegisterEvent, frame, e)
    if not ok then print_("Could not register " .. e .. ": " .. tostring(err)) end
end

local acc = 0
frame:SetScript("OnUpdate", function(_, dt)
    if not db then return end
    acc = acc + dt
    if acc >= 1 then
        local now, inCombat = GetTime(), UnitAffectingCombat("player")
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
    elseif cmd == "trace" then
        db.traceLoot = not db.traceLoot
        print_("Loot trace " .. (db.traceLoot and "ON: loot a Mote and send me the line." or "off"))
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
        db.focus, db.focusSoft, db.focusAt = name, nil, nil
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
        print_("/qmt show | hide | focus [quest] | scale <n> | alpha <n> | reset | history | debug")
    end
    Refresh()
end
