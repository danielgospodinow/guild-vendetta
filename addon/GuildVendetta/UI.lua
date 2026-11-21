-- Main window (Blizzard ButtonFrameTemplate + ScrollBox), minimap button, settings panel, /gv.
local _, ns = ...

local ICON = "Interface\\Icons\\Ability_Warrior_Revenge"
local LAYOUTS = { -- per tab: header, x, width, justify
  { { "#", 6, 24, "RIGHT" }, { "Enemy", 38, 170, "LEFT" }, { "Score", 212, 46, "CENTER" }, { "Lvl", 258, 30, "CENTER" },
    { "Victims", 292, 150, "LEFT" }, { "Where", 446, 100, "LEFT" }, { "When", 548, 44, "RIGHT" } },
  { { "#", 6, 24, "RIGHT" }, { "Guildie", 38, 200, "LEFT" }, { "Vendettas", 242, 70, "CENTER" },
    { "Last taken down", 316, 220, "LEFT" }, { "When", 548, 44, "RIGHT" } },
}
local TABS = { "Vendetta list", "Revengers" }
local MAXCOLS = 7
local expanded = {}

local function ago(t)
  local d = math.max(0, GetServerTime() - t)
  if d < 3600 then return math.floor(d / 60) .. "m" end
  if d < 86400 then return math.floor(d / 3600) .. "h" end
  return math.floor(d / 86400) .. "d"
end

-- "3-1": their kills on us (red) vs our vendettas on them (green)
local function score(row) return "|cffff5050" .. row.count .. "|r-|cff50ff50" .. row.ours .. "|r" end

function ns.Remove(key)
  local e = { k = "R", t = GetServerTime(), en = key, by = ns.Name(UnitName("player")) }
  e.id = ns.RemoveId(key, e.t)
  if ns.AddEvent(e) then ns.Broadcast(e) end
end

StaticPopupDialogs.GUILDVENDETTA_REMOVE = {
  text = "Remove %s from the guild's vendetta list?\n\nThis applies to everyone in the guild, and their score starts over.",
  button1 = YES, button2 = NO, timeout = 0, whileDead = true, hideOnEscape = true,
  OnAccept = function(_, key) ns.Remove(key) end,
}

-- Window -----------------------------------------------------------------------

local frame = CreateFrame("Frame", "GuildVendettaFrame", UIParent, "ButtonFrameTemplate")
frame:SetSize(660, 460)
frame:SetPoint("CENTER")
frame:SetMovable(true)
frame:EnableMouse(true)
frame:SetClampedToScreen(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:SetTitle("Guild Vendetta")
frame:SetPortraitToAsset(ICON)
frame:Hide()
tinsert(UISpecialFrames, frame:GetName()) -- Escape closes it

local search = CreateFrame("EditBox", nil, frame, "SearchBoxTemplate")
search:SetSize(180, 20)
search:SetPoint("TOPLEFT", 70, -32)
local count = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
count:SetPoint("TOPRIGHT", -14, -36)

local headers = {}
for i = 1, MAXCOLS do
  headers[i] = frame.Inset:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
end

local function layout(fontStrings, parent, y)
  local cols = LAYOUTS[frame.selectedTab or 1]
  for i, fs in ipairs(fontStrings) do
    local c = cols[i]
    fs:SetShown(c ~= nil)
    if c then
      fs:ClearAllPoints()
      fs:SetPoint(y and "TOPLEFT" or "LEFT", parent, y and "TOPLEFT" or "LEFT", y and c[2] or c[2] - 4, y or 0)
      fs:SetWidth(c[3])
      fs:SetJustifyH(c[4])
    end
  end
  return cols
end

for i, label in ipairs(TABS) do
  local tab = CreateFrame("Button", "GuildVendettaFrameTab" .. i, frame, "PanelTabButtonTemplate")
  tab:SetID(i)
  tab:SetText(label)
  if i == 1 then
    tab:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 11, 2)
  else
    tab:SetPoint("LEFT", _G["GuildVendettaFrameTab" .. (i - 1)], "RIGHT", 3, 0)
  end
  tab:SetScript("OnClick", function(self)
    PanelTemplates_SetTab(frame, self:GetID())
    PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
    ns.RefreshWindow()
  end)
  PanelTemplates_TabResize(tab, 0)
end
PanelTemplates_SetNumTabs(frame, #TABS)
PanelTemplates_SetTab(frame, 1)

local footer = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
footer:SetPoint("BOTTOMLEFT", 12, 9)
local settingsButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
settingsButton:SetSize(96, 22)
settingsButton:SetPoint("BOTTOMRIGHT", -6, 4)
settingsButton:SetText(SETTINGS)
settingsButton:SetScript("OnClick", function()
  if ns.settingsCategory then Settings.OpenToCategory(ns.settingsCategory:GetID()) end
end)

local scroll = CreateFrame("Frame", nil, frame.Inset, "WowScrollBoxList")
scroll:SetPoint("TOPLEFT", 4, -22)
scroll:SetPoint("BOTTOMRIGHT", -22, 4)
local bar = CreateFrame("EventFrame", nil, frame.Inset, "MinimalScrollBar")
bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 6, 0)
bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 6, 0)

local function setupRow(button)
  button.cols = {}
  for i = 1, MAXCOLS do
    local fs = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetWordWrap(false)
    button.cols[i] = fs
  end
  button.detail = button:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  button.detail:SetPoint("LEFT", 40, 0)
  button.detail:SetPoint("RIGHT", -4, 0)
  button.detail:SetJustifyH("LEFT")
  button.detail:SetWordWrap(false)
  button:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  button.remove = CreateFrame("Button", nil, button, "UIPanelCloseButtonNoScripts")
  button.remove:SetSize(20, 20)
  button.remove:SetPoint("RIGHT", 2, 0)
  button.remove:SetScript("OnClick", function()
    local row = button.item.row
    StaticPopup_Show("GUILDVENDETTA_REMOVE", ns.Colored(row.name, row.class), nil, row.key)
  end)
  button:SetScript("OnClick", function()
    local item = button.item
    if item.row then
      expanded[item.row.key] = not expanded[item.row.key]
      ns.RefreshWindow()
    end
  end)
end

local function killText(e)
  local names = {}
  for i, x in ipairs(e.en) do names[i] = (x.kb and "*" or "") .. x.n end
  local where = e.sub ~= "" and (e.zone .. ", " .. e.sub) or e.zone
  local coords = e.x and string.format(" (%.1f, %.1f)", e.x * 100, e.y * 100) or ""
  return string.format("killed %s (%s) in %s%s, %s ago, by %s", ns.Colored(e.vic, e.vclass), ns.Level(e.vlvl),
    where, coords, ago(e.t), table.concat(names, ", "))
end

local function vendettaText(v)
  return string.format("|cff50ff50taken down by %s in %s, %s ago|r", table.concat(v.by, ", "), v.zone, ago(v.t))
end

local function victims(row)
  local names = {}
  for i, k in ipairs(row.victims) do names[i] = ns.Colored(k.vic, k.vclass) end
  return table.concat(names, ", ")
end

local function initRow(button, item)
  if not button.cols then setupRow(button) end
  button.item = item
  local detail = item.kill or item.vendetta
  local cols = layout(button.cols, button)
  if detail then
    for _, fs in ipairs(button.cols) do fs:Hide() end
  end
  button.detail:SetShown(detail ~= nil)
  button.remove:SetShown(item.row ~= nil)
  local v = button.cols
  if item.kill then
    button.detail:SetText(killText(item.kill))
  elseif item.vendetta then
    button.detail:SetText(vendettaText(item.vendetta))
  elseif item.row then
    local row = item.row
    v[1]:SetText(row.rank)
    v[2]:SetText((expanded[row.key] and "- " or "+ ") .. ns.Colored(row.name, row.class))
    v[3]:SetText(score(row))
    v[4]:SetText(ns.Level(row.level))
    v[5]:SetText(victims(row))
    v[6]:SetText(row.lastVictim.zone)
    v[7]:SetText(ago(row.last))
  else
    local r = item.rev
    v[1]:SetText(r.rank)
    v[2]:SetText(r.name)
    v[3]:SetText(r.count)
    v[4]:SetText(ns.Colored(r.lastEnemy, r.lastClass))
    v[5]:SetText(ago(r.last))
  end
  return cols
end

local view = CreateScrollBoxListLinearView()
view:SetElementExtent(20)
view:SetElementInitializer("Button", initRow)
ScrollUtil.InitScrollBoxListWithScrollBar(scroll, bar, view)

local function matches(name, filter) return filter == "" or name:lower():find(filter, 1, true) end

function ns.RefreshWindow()
  if not frame:IsShown() then return end
  local cols = layout(headers, frame.Inset, -6)
  for i, h in ipairs(headers) do h:SetText(cols[i] and cols[i][1] or "") end
  local filter = search:GetText():lower()
  local items = {}
  if (frame.selectedTab or 1) == 1 then
    for _, row in ipairs(ns.view.rows) do
      if matches(row.name, filter) then
        items[#items + 1] = { row = row }
        if expanded[row.key] then
          -- every kill and every vendetta on this enemy, newest first
          local lines = {}
          for _, k in ipairs(row.kills) do lines[#lines + 1] = { t = k.t, kill = k } end
          for _, d in ipairs(row.vendettas) do lines[#lines + 1] = { t = d.t, vendetta = d } end
          table.sort(lines, function(a, b) return a.t > b.t end)
          for _, l in ipairs(lines) do items[#items + 1] = l end
        end
      end
    end
    local n = #ns.view.rows
    count:SetText(n .. (n == 1 and " enemy" or " enemies"))
  else
    for _, r in ipairs(ns.view.revengers) do
      if matches(r.name, filter) then items[#items + 1] = { rev = r } end
    end
    local n = #ns.view.revengers
    count:SetText(n .. (n == 1 and " revenger" or " revengers"))
  end
  scroll:SetDataProvider(CreateDataProvider(items), ScrollBoxConstants.RetainScrollPosition)

  local h = ns.health
  if h.secret > 0 or h.recap == "no recap events" then
    footer:SetText("|cffff2020The game hid your last death's details: it may not be recorded (/gv status)|r")
  elseif not ns.guildKey then
    footer:SetText("Not in a guild.")
  else
    local s = ns.guildDB.lastSync
    footer:SetText(s and string.format("Last sync: %s ago from %s", ago(s.t), s.from) or "Last sync: none yet")
  end
end

search:HookScript("OnTextChanged", ns.RefreshWindow)
frame:SetScript("OnShow", ns.RefreshWindow)
table.insert(ns.listeners, ns.RefreshWindow)

function ns.ToggleWindow() frame:SetShown(not frame:IsShown()) end

-- Minimap button -----------------------------------------------------------------

local mini = CreateFrame("Button", "GuildVendettaMinimapButton", Minimap)
mini:SetSize(31, 31)
mini:SetFrameStrata("MEDIUM")
mini:SetFrameLevel(8)
mini:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
local icon = mini:CreateTexture(nil, "BACKGROUND")
icon:SetTexture(ICON)
icon:SetSize(20, 20)
icon:SetPoint("TOPLEFT", 7, -5)
local border = mini:CreateTexture(nil, "OVERLAY")
border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
border:SetSize(53, 53)
border:SetPoint("TOPLEFT")

local function placeMinimap()
  local a, r = math.rad(ns.settings.minimapAngle), Minimap:GetWidth() / 2 + 10
  mini:ClearAllPoints()
  mini:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
  mini:SetShown(ns.settings.minimap)
end

mini:RegisterForDrag("LeftButton")
mini:SetScript("OnDragStart", function(self)
  self:SetScript("OnUpdate", function()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local s = Minimap:GetEffectiveScale()
    ns.settings.minimapAngle = math.deg(math.atan2(py / s - my, px / s - mx))
    placeMinimap()
  end)
end)
mini:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
mini:SetScript("OnClick", ns.ToggleWindow)
mini:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:SetText("Guild Vendetta")
  GameTooltip:AddLine(#ns.view.rows .. " enemies on the list", 1, 1, 1)
  GameTooltip:AddLine("Click to open, drag to move.", 0.7, 0.7, 0.7)
  GameTooltip:Show()
end)
mini:SetScript("OnLeave", GameTooltip_Hide)

-- Settings (Options > AddOns) -----------------------------------------------------------

local function registerSettings()
  local cat = Settings.RegisterVerticalLayoutCategory("Guild Vendetta")
  local function add(key, name)
    return Settings.RegisterAddOnSetting(cat, "GuildVendetta_" .. key, key, ns.settings,
      type(ns.DEFAULTS[key]), name, ns.DEFAULTS[key])
  end
  Settings.CreateCheckbox(cat, add("flash", "Screen flash"), "Flash the screen red when a listed enemy is nearby.")
  Settings.CreateCheckbox(cat, add("message", "Warning message"), "Show a raid-warning style message.")
  Settings.CreateCheckbox(cat, add("sound", "Warning sound"), "Play the raid warning sound.")
  Settings.CreateCheckbox(cat, add("announce", "Announce in guild chat"),
    "Post guildie deaths and successful vendettas in guild chat (visible to the whole guild).")
  local opts = Settings.CreateSliderOptions(1, 30, 1)
  opts:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right)
  Settings.CreateSlider(cat, add("cooldown", "Alert cooldown (minutes)"), opts,
    "Minimum time between alerts for the same enemy.")
  local mm = add("minimap", "Minimap button")
  mm:SetValueChangedCallback(placeMinimap)
  Settings.CreateCheckbox(cat, mm, "Show the minimap button.")
  Settings.RegisterAddOnCategory(cat)
  ns.settingsCategory = cat
end

table.insert(ns.onLoaded, function()
  placeMinimap()
  local ok, err = pcall(registerSettings)
  if not ok then ns.Print("settings panel unavailable (%s); defaults are used.", tostring(err)) end
end)

-- Slash command -----------------------------------------------------------------------

SLASH_GUILDVENDETTA1 = "/gv"
SLASH_GUILDVENDETTA2 = "/vendetta"
SlashCmdList.GUILDVENDETTA = function(arg)
  arg = (arg or ""):lower()
  if arg == "sync" then
    ns.RequestSync()
    ns.Print("asking online guildmates for missing entries.")
  elseif arg == "test" then
    ns.Alert({ name = "Gankston Example", class = "ROGUE", level = 60, count = 3, ours = 1,
      kills = { { vic = ns.Name(UnitName("player")) } } })
  elseif arg == "status" then
    local n = 0
    for _ in pairs(ns.events) do n = n + 1 end
    ns.Print("guild=%s events=%d enemies=%d deathRecap=%s secretValues=%d", tostring(ns.guildKey), n,
      #ns.view.rows, ns.health.recap, ns.health.secret)
  elseif arg == "" then
    ns.ToggleWindow()
  else
    ns.Print("/gv (window), /gv sync, /gv test (preview alert), /gv status")
  end
end
