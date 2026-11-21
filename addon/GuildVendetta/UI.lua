-- Main window (Blizzard ButtonFrameTemplate + ScrollBox), minimap button, settings panel, /gv.
local _, ns = ...

local ICON = "Interface\\Icons\\Ability_Warrior_Revenge"
local COLS = { -- header, x, width, justify
  { "#", 6, 24, "RIGHT" }, { "Enemy", 38, 160, "LEFT" }, { "Kills", 198, 40, "CENTER" },
  { "Lvl", 238, 34, "CENTER" }, { "Last victim", 276, 110, "LEFT" }, { "Where", 390, 140, "LEFT" },
  { "When", 534, 40, "RIGHT" },
}
local expanded = {}

local function ago(t)
  local d = math.max(0, GetServerTime() - t)
  if d < 3600 then return math.floor(d / 60) .. "m" end
  if d < 86400 then return math.floor(d / 3600) .. "h" end
  return math.floor(d / 86400) .. "d"
end

function ns.Remove(key)
  local e = { k = "R", t = GetServerTime(), en = key, by = ns.Name(UnitName("player")) }
  e.id = ns.RemoveId(key, e.t)
  if ns.AddEvent(e) then ns.Broadcast(e) end
end

StaticPopupDialogs.GUILDVENDETTA_REMOVE = {
  text = "Remove %s from the guild's vendetta list?\n\nThis applies to everyone in the guild.",
  button1 = YES, button2 = NO, timeout = 0, whileDead = true, hideOnEscape = true,
  OnAccept = function(_, key) ns.Remove(key) end,
}

-- Window -----------------------------------------------------------------------

local frame = CreateFrame("Frame", "GuildVendettaFrame", UIParent, "ButtonFrameTemplate")
frame:SetSize(620, 460)
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

for _, c in ipairs(COLS) do
  local h = frame.Inset:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  h:SetPoint("TOPLEFT", c[2], -6)
  h:SetWidth(c[3])
  h:SetJustifyH(c[4])
  h:SetText(c[1])
end

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
  for i, c in ipairs(COLS) do
    local fs = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetPoint("LEFT", c[2] - 4, 0)
    fs:SetWidth(c[3])
    fs:SetJustifyH(c[4])
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

local function initRow(button, item)
  if not button.cols then setupRow(button) end
  button.item = item
  local row = item.row
  for _, fs in ipairs(button.cols) do fs:SetShown(row ~= nil) end
  button.detail:SetShown(row == nil)
  button.remove:SetShown(row ~= nil)
  if not row then
    button.detail:SetText(killText(item.kill))
    return
  end
  local last = row.kills[1]
  local v = button.cols
  v[1]:SetText(row.rank)
  v[2]:SetText((expanded[row.key] and "- " or "+ ") .. ns.Colored(row.name, row.class))
  v[3]:SetText(row.count)
  v[4]:SetText(ns.Level(row.level))
  v[5]:SetText(ns.Colored(last.vic, last.vclass))
  v[6]:SetText(last.zone)
  v[7]:SetText(ago(last.t))
end

local view = CreateScrollBoxListLinearView()
view:SetElementExtent(20)
view:SetElementInitializer("Button", initRow)
ScrollUtil.InitScrollBoxListWithScrollBar(scroll, bar, view)

function ns.RefreshWindow()
  if not frame:IsShown() then return end
  local filter = search:GetText():lower()
  local items, shown = {}, 0
  for _, row in ipairs(ns.view.rows) do
    if filter == "" or row.name:lower():find(filter, 1, true) then
      shown = shown + 1
      items[#items + 1] = { row = row }
      if expanded[row.key] then
        for _, e in ipairs(row.kills) do items[#items + 1] = { kill = e } end
      end
    end
  end
  scroll:SetDataProvider(CreateDataProvider(items), ScrollBoxConstants.RetainScrollPosition)
  count:SetText(shown .. (shown == 1 and " enemy" or " enemies"))

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
    ns.Alert({ name = "Gankston Example", class = "ROGUE", level = 60, count = 3,
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
