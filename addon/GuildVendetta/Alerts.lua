-- Proximity alerts: a listed enemy seen via nameplate, target, mouseover or combat log
-- triggers a red screen flash, a raid-warning message and a sound (per-enemy cooldown).
local _, ns = ...

local lastAlert = {} -- enemy name -> GetTime() of last alert

function ns.Colored(name, class)
  local c = class and RAID_CLASS_COLORS[class]
  name = Ambiguate(name, "none")
  return c and ("|c" .. c.colorStr .. name .. "|r") or name
end

function ns.Level(l) return (l and l > 0) and tostring(l) or "??" end

local flash = CreateFrame("Frame", nil, UIParent)
flash:SetAllPoints()
flash:SetFrameStrata("FULLSCREEN_DIALOG")
flash:EnableMouse(false)
flash:Hide()
local tex = flash:CreateTexture(nil, "BACKGROUND")
tex:SetAllPoints()
tex:SetTexture("Interface\\FullScreenTextures\\LowHealth")
tex:SetBlendMode("ADD")
tex:SetVertexColor(1, 0, 0)
local pulse = flash:CreateAnimationGroup()
pulse:SetLooping("BOUNCE")
local fade = pulse:CreateAnimation("Alpha")
fade:SetFromAlpha(0)
fade:SetToAlpha(1)
fade:SetDuration(0.3)

local function flashScreen()
  flash:Show()
  pulse:Play()
  C_Timer.After(1.8, function()
    pulse:Stop()
    flash:Hide()
  end)
end

function ns.Alert(row)
  local s = ns.settings
  local class = LOCALIZED_CLASS_NAMES_MALE[row.class] or row.class or "?"
  local victim = Ambiguate(row.kills[1].vic, "guild")
  local what = row.count == 1 and ("killed " .. victim) or ("killed " .. row.count .. " guildies, last " .. victim)
  local text = string.format("VENDETTA: %s (%s, %s) %s", ns.Colored(row.name, row.class), class, ns.Level(row.level), what)
  if s.message then RaidNotice_AddMessage(RaidWarningFrame, text, ChatTypeInfo["RAID_WARNING"]) end
  if s.sound then PlaySound(SOUNDKIT.RAID_WARNING, "Master") end
  if s.flash then flashScreen() end
  print(text)
end

function ns.Seen(name, guid)
  if not name or not ns.settings then return end
  local row = (guid and not ns.Secret(guid) and ns.view.byKey[guid]) or ns.view.byKey[ns.FullName(name)]
  if not row or IsInInstance() then return end -- world PvP only
  local now = GetTime()
  if lastAlert[row.key] and now - lastAlert[row.key] < ns.settings.cooldown * 60 then return end
  lastAlert[row.key] = now
  ns.Alert(row)
end

local function onUnit(unit)
  if not UnitExists(unit) then return end
  local isPlayer, name, realm = UnitIsPlayer(unit), UnitName(unit)
  local guid, level = UnitGUID(unit), UnitLevel(unit)
  if ns.Secret(isPlayer) or ns.Secret(name) or ns.Secret(realm) or not isPlayer then return end
  if not ns.Secret(guid) and not ns.Secret(level) and level > 0 then ns.levels[guid] = level end
  ns.Seen(ns.FullName(name, realm), guid)
end

local f = CreateFrame("Frame")
f:RegisterEvent("NAME_PLATE_UNIT_ADDED")
f:RegisterEvent("PLAYER_TARGET_CHANGED")
f:RegisterEvent("UPDATE_MOUSEOVER_UNIT")
f:SetScript("OnEvent", function(_, ev, unit)
  if ev == "PLAYER_TARGET_CHANGED" then unit = "target" elseif ev == "UPDATE_MOUSEOVER_UNIT" then unit = "mouseover" end
  onUnit(unit)
end)
