-- PoisonBucket -- the toggleable poison-alert chip, the poison rack, and the
-- creature-type weapon-set swapper. Standalone build of HoryUI's poisonbucket
-- module (kept in sync with it -- see the HoryUI repo); DORMANT while the
-- full HoryUI addon is loaded, since HoryUI ships its own copy.
-- Chip: LEFT-click arms/disarms (vivid = armed, grey = off); RIGHT-click opens
-- the weapon-sets menu. While armed, if an equipped weapon has no poison (or is
-- under LOWCHARGES charges), the chip "heartbeats" garnet and rings the bell
-- RING_COUNT times, repeating every RING_CYCLE seconds until fixed.
-- Rack: drop poison items from the bags onto the window to rack them (any
-- number; the row is dynamic, no empty slots). The rack works as an EXTRA
-- SKILLBAR: each racked poison permanently claims a hidden high action slot
-- (see PlaceRacked). LEFT-click applies to the MAIN hand, RIGHT-click to the
-- OFF hand; SHIFT-click removes it (freeing its slot). 1.12 has no
-- GetCursorInfo, so the dropped
-- item is identified by scanning the bags for the LOCKED slot the pickup left
-- behind. Racked entries persist in PoisonBucketDB.poisonrack.
-- Swap: Elemental / Giant / Undead / Mechanical enemies need Dissolvent
-- Poison, everything else a standard poison. The weapon's current poison is
-- read off its tooltip enchant line (the weaponpoison technique); on a
-- mismatch a pulsing swap button appears -- click (or the key binding,
-- Bindings.xml -> PoisonBucket.Swap) equips the weapon pair saved for the
-- needed poison class. The two pairs are saved from the currently equipped
-- weapons via the chip's right-click menu ("Use equipped").

-- key-binding display strings (Bindings.xml); must exist at file load
BINDING_HEADER_POISONBUCKET = "Poison Bucket"
BINDING_NAME_POISONBUCKET_SWAP = "Swap poison weapon set"

local PB = PoisonBucket

local function BootPoisonBucket()
  local C = PB.color
  local SIZE = 34            -- chip size
  local RS = 26              -- rack / swap icon size
  local GAP = 4              -- gap between chips
  local LOWCHARGES = 10      -- alert when a poison drops below this many charges
  local PERIOD = 0.8         -- one heartbeat cycle: lub, dub, rest (fast = urgent)
  local BEAT = 0.16          -- length of a single pulse within the cycle
  local GLOWMAX = 0.35       -- peak alpha of the additive garnet wash
  local SOUND = "Interface\\AddOns\\PoisonBucket\\media\\horn.wav"  -- 16-bit PCM (1.12 can't play 24-bit)
  local RING_COUNT = 3       -- bell rings per alert cycle...
  local RING_GAP = 1.2       -- ...this far apart...
  local RING_CYCLE = 30      -- ...repeating every this many seconds
  local MAINHAND, OFFHAND = 16, 17
  local FALLBACK = "Interface\\Icons\\Ability_Poisons"
  local CHIPICON = "Interface\\AddOns\\PoisonBucket\\media\\poison-bucket"  -- custom 64x64 TGA
  local SWAPICON = "Interface\\Icons\\Ability_DualWield"
  local DISSOLVENT = "^Dissolvent"   -- Turtle's poison for the SPECIAL types
  local SPECIAL = { Elemental = true, Giant = true, Undead = true, Mechanical = true }
  local SETLABEL = { diss = "Dissolvent", std = "Standard" }

  local GetWeaponEnchantInfo, GetInventoryItemLink, OffhandHasWeapon =
        GetWeaponEnchantInfo, GetInventoryItemLink, OffhandHasWeapon
  local GetContainerNumSlots, GetContainerItemLink, GetContainerItemInfo =
        GetContainerNumSlots, GetContainerItemLink, GetContainerItemInfo
  local UnitExists, UnitCanAttack, UnitIsDead, UnitCreatureType =
        UnitExists, UnitCanAttack, UnitIsDead, UnitCreatureType
  local GetTime, sin, mod, getn = GetTime, math.sin, math.mod, table.getn
  local PI = 3.14159265

  if type(PoisonBucketDB.poisonrack) ~= "table" then PoisonBucketDB.poisonrack = {} end
  if type(PoisonBucketDB.poisonsets) ~= "table" then PoisonBucketDB.poisonsets = {} end
  if type(PoisonBucketDB.poisonsets.diss) ~= "table" then PoisonBucketDB.poisonsets.diss = {} end
  if type(PoisonBucketDB.poisonsets.std) ~= "table" then PoisonBucketDB.poisonsets.std = {} end

  -- window container: invisible; the chip + each rack icon carry their own
  -- backdrop (the weaponpoison look), so the dynamic width never shows a tray
  local f = CreateFrame("Frame", "PoisonBucketFrame", UIParent)
  f:SetWidth(SIZE)
  f:SetHeight(SIZE)
  f:SetFrameStrata("MEDIUM")

  -- every clickable here is a real Button firing OnClick: on this client an
  -- item-use cast is honored from a Button's OnClick or a key press, but NOT
  -- from a plain Frame's OnMouseUp (measured: the same UseAction call worked
  -- from /run and from real bar buttons, silently did nothing from OnMouseUp)
  local chip = CreateFrame("Button", nil, f)
  chip:SetWidth(SIZE)
  chip:SetHeight(SIZE)
  chip:SetPoint("LEFT", f, "LEFT", 0, 0)
  chip:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  PB.CreateBackdrop(chip)

  chip.icon = chip:CreateTexture(nil, "ARTWORK")
  chip.icon:SetTexture(CHIPICON)  -- custom art: no border crop (drawn edge-to-edge)
  chip.icon:SetPoint("TOPLEFT", chip, "TOPLEFT", 1, -1)
  chip.icon:SetPoint("BOTTOMRIGHT", chip, "BOTTOMRIGHT", -1, 1)

  -- the alert wash: an additive garnet sheen breathing over the icon
  chip.glow = chip:CreateTexture(nil, "OVERLAY")
  chip.glow:SetTexture(PB.tex.white)
  chip.glow:SetBlendMode("ADD")
  chip.glow:SetAllPoints(chip.icon)
  local ahi = C.accent_hi
  chip.glow:SetVertexColor(ahi[1], ahi[2], ahi[3])
  chip.glow:SetAlpha(0)

  local alerting = false
  local beatStart = 0
  local soundAt = 0          -- start of the current bell cycle
  local rings = 0            -- bells rung in the current cycle

  -- vivid <-> grey (desaturate when the shader allows it, dim either way --
  -- the dim alone carries the "off" read on shaderless hardware)
  local function TintIcon(tex, vivid)
    if vivid then
      if tex.SetDesaturated then tex:SetDesaturated(nil) end
      tex:SetVertexColor(1, 1, 1)
    else
      if tex.SetDesaturated then tex:SetDesaturated(1) end
      tex:SetVertexColor(0.45, 0.45, 0.45)
    end
  end

  local function Armed()
    return PoisonBucketDB.poisonbucketOn ~= false   -- default on
  end

  local function PaintArmed()
    TintIcon(chip.icon, Armed())
  end

  local function StopAlert()
    if not alerting then return end
    alerting = false
    chip.glow:SetAlpha(0)
    if chip.hover then
      chip.backdrop:SetBackdropBorderColor(ahi[1], ahi[2], ahi[3], 1)
    else
      chip.backdrop:SetBackdropBorderColor(0, 0, 0, 1)
    end
  end

  local function StartAlert()
    if alerting then return end
    alerting = true
    beatStart = GetTime()
    soundAt = beatStart        -- bell cycle starts now; rings fire from OnUpdate
    rings = 0
  end

  -- ==========================================================================
  -- weapon poison identity -- 1.12 exposes no temp-enchant name API, so the
  -- poison is read from the weapon tooltip's enchant line (the line ending in
  -- a "(N min)"/"(N sec)" duration) via a hidden scanner -- the weaponpoison
  -- technique. Cached per hand; rescanned only on inventory change or when the
  -- enchant expiry RISES (= a fresh poison was applied).
  -- ==========================================================================
  local scan = CreateFrame("GameTooltip", "PoisonBucketScan", UIParent, "GameTooltipTemplate")
  scan:SetOwner(WorldFrame, "ANCHOR_NONE")

  local function WeaponPoisonName(slot)
    scan:SetOwner(WorldFrame, "ANCHOR_NONE")
    scan:ClearLines()
    if not scan:SetInventoryItem("player", slot) then return nil end
    for i = 2, scan:NumLines() do -- skip the title so a weapon NAMED "...Poison..." can't match
      local fs = getglobal("PoisonBucketScanTextLeft" .. i)
      local txt = fs and fs:GetText()
      if txt then
        local low = string.lower(txt)
        if string.find(low, "%(%d+ min%)") or string.find(low, "%(%d+ sec%)") then
          local _, _, base = string.find(txt, "^(.-%sPoison)")
          if base then return base end
        end
      end
    end
    return nil
  end

  local pcache = { [16] = nil, [17] = nil }   -- hand -> poison base name (nil = none)
  local lastExp = { [16] = 0, [17] = 0 }
  local needScan = true

  -- ==========================================================================
  -- weapon sets + swap
  -- ==========================================================================
  local function EquippedName(slot)
    local link = GetInventoryItemLink("player", slot)
    if not link then return nil end
    local _, _, nm = string.find(link, "%[(.-)%]")
    return nm
  end

  local function FindInBags(name)
    for bag = 0, 4 do
      for slot = 1, GetContainerNumSlots(bag) do
        local link = GetContainerItemLink(bag, slot)
        if link then
          local _, _, nm = string.find(link, "%[(.-)%]")
          if nm == name then return bag, slot end
        end
      end
    end
  end

  -- equip `name` into invslot via the cursor (works in combat -- weapons only);
  -- the displaced weapon is parked in the bag slot the new one came from
  local function EquipByName(name, invslot)
    if not name then return end              -- unset half of a set: leave the hand alone
    if EquippedName(invslot) == name then return end
    local bag, slot = FindInBags(name)
    if not bag then
      UIErrorsFrame:AddMessage(name .. " is not in your bags", 1, 0.1, 0.1)
      return
    end
    PickupContainerItem(bag, slot)
    if not CursorHasItem() then return end   -- locked slot / in-flight action
    PickupInventoryItem(invslot)
    if CursorHasItem() then PickupContainerItem(bag, slot) end
  end

  local function EquipSet(key)
    if CursorHasItem() or SpellIsTargeting() then return end
    local s = PoisonBucketDB.poisonsets[key]
    if not (s.mh or s.oh) then
      UIErrorsFrame:AddMessage("No " .. SETLABEL[key] .. " weapons saved -- right-click the poison chip", 1, 0.1, 0.1)
      return
    end
    EquipByName(s.mh, MAINHAND)
    EquipByName(s.oh, OFFHAND)
    needScan = true
  end

  local swapNeed = nil       -- "diss" | "std": the set that SHOULD be equipped
  local swapStart = 0        -- pulse phase anchor for the swap button

  -- which poison class is on the weapons right now (MH first, OH fallback)
  local function CurrentPoisonClass()
    local p = pcache[16] or pcache[17]
    if not p then return nil end
    if string.find(p, DISSOLVENT) then return "diss" end
    return "std"
  end

  -- which poison class the current target wants (nil = no live enemy target)
  local function TargetPoisonNeed()
    if not UnitExists("target") or not UnitCanAttack("player", "target")
      or UnitIsDead("target") then return nil end
    local ct = UnitCreatureType("target")
    if ct and SPECIAL[ct] then return "diss" end
    return "std"
  end

  -- the keybinding entry point (Bindings.xml). With a mismatch showing it
  -- equips the needed set; otherwise it toggles to the other pair (decided by
  -- weapon identity, so it works even with no poisons applied).
  function PoisonBucket.Swap()
    local key = swapNeed
    if not key then
      local mhn = EquippedName(MAINHAND)
      if mhn and PoisonBucketDB.poisonsets.diss.mh == mhn then key = "std" else key = "diss" end
    end
    EquipSet(key)
  end

  local swapBtn = CreateFrame("Button", nil, f)
  swapBtn:SetWidth(RS)
  swapBtn:SetHeight(RS)
  swapBtn:RegisterForClicks("LeftButtonUp")
  PB.CreateBackdrop(swapBtn)
  swapBtn.icon = swapBtn:CreateTexture(nil, "ARTWORK")
  swapBtn.icon:SetTexture(SWAPICON)
  swapBtn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  swapBtn.icon:SetPoint("TOPLEFT", swapBtn, "TOPLEFT", 1, -1)
  swapBtn.icon:SetPoint("BOTTOMRIGHT", swapBtn, "BOTTOMRIGHT", -1, 1)
  swapBtn.glow = swapBtn:CreateTexture(nil, "OVERLAY")
  swapBtn.glow:SetTexture(PB.tex.white)
  swapBtn.glow:SetBlendMode("ADD")
  swapBtn.glow:SetAllPoints(swapBtn.icon)
  swapBtn.glow:SetVertexColor(ahi[1], ahi[2], ahi[3])
  swapBtn.glow:SetAlpha(0)
  swapBtn:Hide()

  local function SwapTip()
    GameTooltip:SetOwner(swapBtn, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("Swap Weapons", ahi[1], ahi[2], ahi[3])
    if swapNeed then
      GameTooltip:AddLine("Target needs " .. (swapNeed == "diss" and "Dissolvent Poison" or "standard poisons"),
        C.text[1], C.text[2], C.text[3])
      local s = PoisonBucketDB.poisonsets[swapNeed]
      GameTooltip:AddLine((s.mh or "--") .. "  /  " .. (s.oh or "--"),
        C.text2[1], C.text2[2], C.text2[3])
    end
    GameTooltip:AddLine("Click to equip that pair", C.text3[1], C.text3[2], C.text3[3])
    GameTooltip:AddLine("Bindable: Key Bindings > Poison Bucket", C.text3[1], C.text3[2], C.text3[3])
    GameTooltip:Show()
  end

  swapBtn:SetScript("OnClick", function() PoisonBucket.Swap() end)
  swapBtn:SetScript("OnEnter", SwapTip)
  swapBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- ==========================================================================
  -- layout -- chip, rack row, then the swap button when a mismatch is showing
  -- ==========================================================================
  local function Relayout()
    local n = getn(PoisonBucketDB.poisonrack)
    local w = SIZE + n * (RS + GAP)          -- right edge of the last rack icon
    if swapNeed then
      swapBtn:ClearAllPoints()
      swapBtn:SetPoint("LEFT", f, "LEFT", w + GAP, 0)
      swapBtn:Show()
      w = w + GAP + RS
    else
      swapBtn:Hide()
    end
    f:SetWidth(w)
  end

  -- a set counts as configured once anything is assigned to it. The whole
  -- swap feature (button + auto-swap) stays out of the way unless BOTH sets
  -- are configured -- a player running one weapon pair isn't swapping, so
  -- don't bother them with a button they can't use.
  local function SetReady(s)
    return (s.mh or s.oh) and true or false
  end

  local function UpdateSwap()
    local need = nil
    if Armed() and SetReady(PoisonBucketDB.poisonsets.diss) and SetReady(PoisonBucketDB.poisonsets.std) then
      local want = TargetPoisonNeed()
      local cur = CurrentPoisonClass()
      if want and cur and want ~= cur then need = want end
    end
    if need and not swapNeed then
      swapStart = GetTime()                  -- fresh pulse phase on appear
    elseif not need and swapNeed then
      swapBtn.glow:SetAlpha(0)
      swapBtn.backdrop:SetBackdropBorderColor(0, 0, 0, 1)
    end
    if need ~= swapNeed then
      swapNeed = need
      Relayout()
      if GameTooltip:IsOwned(swapBtn) then
        if swapNeed then SwapTip() else GameTooltip:Hide() end
      end
      -- auto-swap: ONE equip attempt per mismatch transition (never re-fired
      -- by the 1s poll, so a missing weapon can't spam); a mismatch only ever
      -- shows when both sets are configured (the UpdateSwap gate above)
      if swapNeed and PoisonBucketDB.poisonAutoswap then
        EquipSet(swapNeed)
      end
    end
  end

  -- ==========================================================================
  -- chip tooltip + the 1s state check
  -- ==========================================================================
  local function HandLine(label, equipped, has, charges)
    if not equipped then
      GameTooltip:AddDoubleLine(label, "no weapon",
        C.text2[1], C.text2[2], C.text2[3], C.text3[1], C.text3[2], C.text3[3])
    elseif not has then
      GameTooltip:AddDoubleLine(label, "no poison",
        C.text2[1], C.text2[2], C.text2[3], ahi[1], ahi[2], ahi[3])
    else
      local n = charges or 0
      if n == 0 then               -- charge-less poison (Crippling): just "on"
        GameTooltip:AddDoubleLine(label, "applied",
          C.text2[1], C.text2[2], C.text2[3], C.text[1], C.text[2], C.text[3])
      else
        local cc = (n < LOWCHARGES) and C.threat or C.text
        GameTooltip:AddDoubleLine(label, n .. " charges",
          C.text2[1], C.text2[2], C.text2[3], cc[1], cc[2], cc[3])
      end
    end
  end

  local function Tip()
    GameTooltip:SetOwner(chip, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("Poison Bucket", ahi[1], ahi[2], ahi[3])
    if Armed() then
      local hasMH, _, mhCharges, hasOH, _, ohCharges = GetWeaponEnchantInfo()
      HandLine("Main Hand", GetInventoryItemLink("player", 16), hasMH, mhCharges)
      HandLine("Off Hand", OffhandHasWeapon(), hasOH, ohCharges)
      GameTooltip:AddLine("Left-click: disable", C.text3[1], C.text3[2], C.text3[3])
    else
      GameTooltip:AddLine("Disabled", C.text3[1], C.text3[2], C.text3[3])
      GameTooltip:AddLine("Left-click: enable", C.text3[1], C.text3[2], C.text3[3])
    end
    GameTooltip:AddLine("Right-click: weapon sets", C.text3[1], C.text3[2], C.text3[3])
    GameTooltip:AddLine("Drop a poison here to rack it", C.text3[1], C.text3[2], C.text3[3])
    GameTooltip:AddLine("Drag: move the window", C.text3[1], C.text3[2], C.text3[3])
    GameTooltip:Show()
  end

  local function Check()
    local hasMH, mhExp, mhCharges, hasOH, ohExp, ohCharges = GetWeaponEnchantInfo()

    -- refresh the per-hand poison identity only when it can have changed
    if not hasMH then pcache[16] = nil
    elseif needScan or (mhExp or 0) > lastExp[16] then pcache[16] = WeaponPoisonName(16) end
    if not hasOH then pcache[17] = nil
    elseif needScan or (ohExp or 0) > lastExp[17] then pcache[17] = WeaponPoisonName(17) end
    lastExp[16] = mhExp or 0
    lastExp[17] = ohExp or 0
    needScan = false

    -- lapse alert: a weapon with no poison, or one about to run dry. MH slot
    -- only ever holds weapons; OH is gated on OffhandHasWeapon() so a shield/
    -- held-in-off-hand frill never nags for a poison it can't take. The charge
    -- threshold only applies when the enchant HAS charges -- charge-less
    -- poisons (Crippling / Mind-numbing report 0) are duration-only and fine.
    local lapse = false
    if Armed() then
      if GetInventoryItemLink("player", 16)
        and (not hasMH or ((mhCharges or 0) > 0 and mhCharges < LOWCHARGES)) then lapse = true end
      if OffhandHasWeapon()
        and (not hasOH or ((ohCharges or 0) > 0 and ohCharges < LOWCHARGES)) then lapse = true end
    end
    if lapse then StartAlert() else StopAlert() end

    UpdateSwap()
    if GameTooltip:IsOwned(chip) then Tip() end
  end

  -- ==========================================================================
  -- rack
  -- ==========================================================================
  local btns = {}
  local rackDirty = false
  local counts = {}          -- racked name -> how many are in the bags
  local RepaintRack          -- forward: handlers below remove/add entries

  -- one bag pass: refresh every racked entry's bag count + cached icon
  local function ScanBags()
    local rack = PoisonBucketDB.poisonrack
    for i = 1, getn(rack) do counts[rack[i].name] = 0 end
    for bag = 0, 4 do
      for slot = 1, GetContainerNumSlots(bag) do
        local link = GetContainerItemLink(bag, slot)
        if link then
          local _, _, nm = string.find(link, "%[(.-)%]")
          if nm and counts[nm] then
            local tex, cnt = GetContainerItemInfo(bag, slot)
            counts[nm] = counts[nm] + (cnt or 1)
            for i = 1, getn(rack) do
              if rack[i].name == nm then rack[i].tex = tex end
            end
          end
        end
      end
    end
  end

  -- Applying works ONLY through the action-bar path here: Nampower's item
  -- hook direct-casts UseContainerItem's poison at the current target (guid 0)
  -- instead of entering item-targeting, so it's silently server-rejected
  -- (measured in Logs\nampower_debug.log -- rejected attempts never reset its
  -- "time since last cast", a real skillbar apply does). So the rack IS an
  -- extra skillbar: each racked poison permanently claims a HIDDEN action slot
  -- (searched from 120 down -- outside the visible bars unless all 10 action
  -- bars are shown), the poison is placed there ONCE at rack time (action
  -- placement is server-persisted, so it survives sessions; an action is only
  -- a reference, the items stay in the bags), and a rack click fires
  -- UseAction(slot, 0) exactly like a real bar button, and FinishTargeting
  -- applies it to the clicked hand. Un-racking frees the slot again.
  local function SlotClaimed(i)
    local rack = PoisonBucketDB.poisonrack
    for k = 1, getn(rack) do
      if rack[k].act == i then return true end
    end
  end

  local function ClaimSlot()
    for i = 120, 1, -1 do
      if not HasAction(i) and not SlotClaimed(i) then return i end
    end
  end

  -- first tooltip line of an action slot (hidden SetAction tooltip scan)
  local function ActionName(id)
    scan:SetOwner(WorldFrame, "ANCHOR_NONE")
    scan:ClearLines()
    scan:SetAction(id)
    local fs = getglobal("PoisonBucketScanTextLeft1")
    return fs and fs:GetText()
  end

  -- make sure e's claimed slot holds its poison; quietly does nothing when the
  -- cursor is busy or the poison isn't in the bags (healed on a later repaint)
  local function PlaceRacked(e)
    if CursorHasItem() or SpellIsTargeting() then return end
    local bag, slot = FindInBags(e.name)
    if not bag then return end
    if not e.act then e.act = ClaimSlot() end
    if not e.act then return end
    PickupContainerItem(bag, slot)
    if not CursorHasItem() then return end
    PlaceAction(e.act)
    if CursorHasItem() then PickupContainerItem(bag, slot) end  -- rejected: put it back
  end

  local function FinishTargeting(hand)
    if SpellIsTargeting() then     -- the glowing-hand "apply to what?" state
      PickupInventoryItem(hand)
      ReplaceEnchant()             -- auto-confirm replacing the current poison
      StaticPopup_Hide("REPLACE_ENCHANT")
    end
  end

  -- the item on the cursor: 1.12 has no GetCursorInfo, but picking an item up
  -- LOCKS its source slot -- find the locked bag slot (or equipment slot, for
  -- a weapon dragged off the character pane) and read its identity
  local function CursorItemInfo()
    for bag = 0, 4 do
      for slot = 1, GetContainerNumSlots(bag) do
        local tex, _, locked = GetContainerItemInfo(bag, slot)
        if locked then
          local link = GetContainerItemLink(bag, slot)
          local _, _, nm = string.find(link or "", "%[(.-)%]")
          if nm then return nm, tex end
        end
      end
    end
    for inv = 0, 19 do
      if IsInventoryItemLocked(inv) then
        local link = GetInventoryItemLink("player", inv)
        local _, _, nm = string.find(link or "", "%[(.-)%]")
        if nm then return nm, GetInventoryItemTexture("player", inv) end
      end
    end
  end

  -- a poison specifically (name ending in "Poison [roman rank]", the
  -- roman-rank pattern) -- what the rack accepts
  local function CursorPoison()
    local nm, tex = CursorItemInfo()
    if nm and string.find(nm, "Poison%s*[IVX]*$") then return nm, tex end
  end

  -- a poison dropped anywhere on the window racks it; anything else stays on
  -- the cursor untouched
  local function TryAddDrop()
    if not CursorHasItem() then return end
    local nm, tex = CursorPoison()
    if not nm then return end
    local rack = PoisonBucketDB.poisonrack
    for i = 1, getn(rack) do
      if rack[i].name == nm then
        UIErrorsFrame:AddMessage(nm .. " is already racked", 1, 0.1, 0.1)
        return
      end
    end
    table.insert(rack, { name = nm, tex = tex })
    ClearCursor()                  -- cancels the pickup: the item snaps home
    RepaintRack()
  end

  local function RackTipFor(b)
    local e = PoisonBucketDB.poisonrack[b.index]
    if not e then return end
    GameTooltip:SetOwner(b, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:ClearLines()
    GameTooltip:AddLine(e.name, ahi[1], ahi[2], ahi[3])
    GameTooltip:AddDoubleLine("In bags", counts[e.name] or 0,
      C.text2[1], C.text2[2], C.text2[3], C.text[1], C.text[2], C.text[3])
    GameTooltip:AddLine("Left-click: main hand", C.text3[1], C.text3[2], C.text3[3])
    GameTooltip:AddLine("Right-click: off hand", C.text3[1], C.text3[2], C.text3[3])
    GameTooltip:AddLine("Shift-click: remove", C.text3[1], C.text3[2], C.text3[3])
    GameTooltip:Show()
  end

  local function RackClick()
    if CursorHasItem() then TryAddDrop() return end
    local e = PoisonBucketDB.poisonrack[this.index]
    if not e then return end
    if IsShiftKeyDown() then
      if e.act then                -- free the claimed action slot again
        PickupAction(e.act)
        ClearCursor()
      end
      table.remove(PoisonBucketDB.poisonrack, this.index)
      GameTooltip:Hide()
      RepaintRack()
      return
    end
    local hand = (arg1 == "RightButton") and OFFHAND or MAINHAND
    if SpellIsTargeting() then return end
    if not GetInventoryItemLink("player", hand) then
      UIErrorsFrame:AddMessage(hand == OFFHAND and "No off-hand weapon to poison"
        or "No main-hand weapon to poison", 1, 0.1, 0.1)
      return
    end
    if not FindInBags(e.name) then
      UIErrorsFrame:AddMessage("No " .. e.name .. " in your bags", 1, 0.1, 0.1)
      return
    end
    -- slot empty (fresh rack / user cleared it) or holding something else:
    -- (re)place it, then use it in the same click (OnClick context is what
    -- the client honors -- the earlier "same event" failure was really the
    -- OnMouseUp context)
    if not e.act or not HasAction(e.act) or ActionName(e.act) ~= e.name then
      if e.act and HasAction(e.act) and ActionName(e.act) ~= e.name then
        e.act = nil                -- someone else's action lives there now
      end
      PlaceRacked(e)
      if not (e.act and HasAction(e.act)) then
        UIErrorsFrame:AddMessage("Couldn't prepare " .. e.name .. " -- try again", 1, 0.1, 0.1)
        return
      end
    end
    UseAction(e.act, 0)            -- the exact bar-button call
    FinishTargeting(hand)
  end

  local function MakeRackButton(i)
    local b = CreateFrame("Button", nil, f)
    b:SetWidth(RS)
    b:SetHeight(RS)
    b:SetPoint("LEFT", f, "LEFT", SIZE + GAP + (i - 1) * (RS + GAP), 0)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    PB.CreateBackdrop(b)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.icon:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
    b.icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
    b.count = b:CreateFontString(nil, "OVERLAY")
    PB.SetFont(b.count, PB.font.number, 9, "OUTLINE")
    b.count:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
    b.index = i
    b:SetScript("OnClick", RackClick)
    b:SetScript("OnReceiveDrag", TryAddDrop)
    b:SetScript("OnEnter", function() RackTipFor(this) end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    btns[i] = b
    return b
  end

  RepaintRack = function()
    ScanBags()
    local rack = PoisonBucketDB.poisonrack
    local n = getn(rack)
    for i = 1, n do
      local b = btns[i] or MakeRackButton(i)
      local e = rack[i]
      local cnt = counts[e.name] or 0
      -- heal the claimed action slot when it's empty (fresh rack, migration,
      -- or the user cleared it); conflicts are resolved at click time
      if cnt > 0 and (not e.act or not HasAction(e.act)) then PlaceRacked(e) end
      b.icon:SetTexture(e.tex or FALLBACK)
      TintIcon(b.icon, cnt > 0)
      b.count:SetText(cnt)
      if cnt > 0 then
        b.count:SetTextColor(C.text[1], C.text[2], C.text[3])
      else
        b.count:SetTextColor(C.text3[1], C.text3[2], C.text3[3])
      end
      b:Show()
    end
    for i = n + 1, getn(btns) do btns[i]:Hide() end
    Relayout()
    -- keep a hovered rack tooltip's count line current
    for i = 1, n do
      if GameTooltip:IsOwned(btns[i]) then RackTipFor(btns[i]) end
    end
  end

  -- ==========================================================================
  -- weapon-sets menu (right-click the chip) -- save the currently equipped
  -- pair as the Dissolvent or Standard set
  -- ==========================================================================
  local menu = CreateFrame("Frame", nil, f)
  menu:SetWidth(240)
  menu:SetHeight(112)
  menu:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, 8)
  menu:SetFrameStrata("DIALOG")
  PB.CreateBackdrop(menu)
  menu:Hide()

  local mtitle = menu:CreateFontString(nil, "OVERLAY")
  PB.SetFont(mtitle, PB.font.normal, 11, "OUTLINE")
  mtitle:SetPoint("TOPLEFT", menu, "TOPLEFT", 8, -8)
  mtitle:SetText("Poison Weapon Sets")
  mtitle:SetTextColor(ahi[1], ahi[2], ahi[3])

  local RefreshMenu          -- forward: the row buttons repaint the menu
  local UpdateSlotHighlights -- forward: cursor-drag highlight painter
  local wslots = {}          -- the 4 weapon-slot chips (diss/std x mh/oh)
  local HANDNAME = { mh = "Main Hand", oh = "Off Hand" }
  local dragInfo = nil       -- {key, hand, name, tex}: a slot ASSIGNMENT mid-drag

  -- ghost icon riding the cursor while an assignment is dragged (there is no
  -- real cursor item during a slot-to-slot drag, so we fake the visual)
  local dragGhost = CreateFrame("Frame", nil, UIParent)
  dragGhost:SetWidth(20)
  dragGhost:SetHeight(20)
  dragGhost:SetFrameStrata("TOOLTIP")
  PB.CreateBackdrop(dragGhost)
  dragGhost.icon = dragGhost:CreateTexture(nil, "ARTWORK")
  dragGhost.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
  dragGhost.icon:SetPoint("TOPLEFT", dragGhost, "TOPLEFT", 1, -1)
  dragGhost.icon:SetPoint("BOTTOMRIGHT", dragGhost, "BOTTOMRIGHT", -1, 1)
  dragGhost:Hide()

  -- release of an assignment drag: over another slot = move (swap when it's
  -- occupied), over the source = no-op, anywhere else = remove
  local function EndSlotDrag()
    local src = dragInfo
    dragInfo = nil
    dragGhost:Hide()
    if not src then
      UpdateSlotHighlights()
      return
    end
    local sets = PoisonBucketDB.poisonsets
    local s = sets[src.key]
    local dst = GetMouseFocus()
    if dst and dst.isWeaponSlot then
      if not (dst.key == src.key and dst.hand == src.hand) then
        local d = sets[dst.key]
        s[src.hand] = d[dst.hand]            -- swap (nil when dst was empty = move)
        s[src.hand .. "Tex"] = d[dst.hand .. "Tex"]
        d[dst.hand] = src.name
        d[dst.hand .. "Tex"] = src.tex
      end
    else
      s[src.hand] = nil                      -- dragged out: unassign
      s[src.hand .. "Tex"] = nil
    end
    RefreshMenu()
    needScan = true
    Check()
  end

  -- one weapon slot chip: shows the assigned weapon's icon with its REAL item
  -- tooltip; drop a weapon (from bags or the character pane) to assign it,
  -- drag between slots to move/swap, drag out (or shift-click) to clear.
  -- Empty = a dark socket.
  local function MakeWeaponSlot(key, handkey, x, y)
    local b = CreateFrame("Button", nil, menu)
    b:SetWidth(24)
    b:SetHeight(24)
    b:SetPoint("TOPLEFT", menu, "TOPLEFT", x, y)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    PB.CreateBackdrop(b)
    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    b.icon:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
    b.icon:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
    b.key = key
    b.hand = handkey
    b.isWeaponSlot = true

    local function Assign()
      if not CursorHasItem() then return end
      local nm, tex = CursorItemInfo()
      if not nm then return end
      local s = PoisonBucketDB.poisonsets[b.key]
      s[b.hand] = nm
      s[b.hand .. "Tex"] = tex
      ClearCursor()                -- cancels the pickup: the item snaps home
      RefreshMenu()
      needScan = true
      Check()
    end

    b:SetScript("OnClick", function()
      if CursorHasItem() then
        Assign()
        return
      end
      if IsShiftKeyDown() then
        local s = PoisonBucketDB.poisonsets[b.key]
        s[b.hand] = nil
        s[b.hand .. "Tex"] = nil
        GameTooltip:Hide()
        RefreshMenu()
        needScan = true
        Check()
      end
    end)
    b:SetScript("OnReceiveDrag", Assign)
    b:SetScript("OnDragStart", function()
      if CursorHasItem() then return end     -- a real item drag ends via OnReceiveDrag
      local s = PoisonBucketDB.poisonsets[this.key]
      local name = s[this.hand]
      if not name then return end
      dragInfo = { key = this.key, hand = this.hand,
                   name = name, tex = s[this.hand .. "Tex"] }
      dragGhost.icon:SetTexture(dragInfo.tex or "Interface\\Icons\\INV_Sword_04")
      dragGhost:Show()
      GameTooltip:Hide()
      UpdateSlotHighlights()
    end)
    b:SetScript("OnDragStop", EndSlotDrag)
    b:SetScript("OnEnter", function()
      this.hover = true
      UpdateSlotHighlights()
      if dragInfo then return end            -- no tooltip mid-drag
      local s = PoisonBucketDB.poisonsets[this.key]
      local name = s[this.hand]
      GameTooltip:SetOwner(this, "ANCHOR_BOTTOMRIGHT")
      if name then
        -- the real item tooltip when the weapon can be found
        local bag, slot = FindInBags(name)
        if bag then
          GameTooltip:SetBagItem(bag, slot)
        elseif EquippedName(MAINHAND) == name then
          GameTooltip:SetInventoryItem("player", MAINHAND)
        elseif EquippedName(OFFHAND) == name then
          GameTooltip:SetInventoryItem("player", OFFHAND)
        else
          GameTooltip:ClearLines()
          GameTooltip:AddLine(name, C.text[1], C.text[2], C.text[3])
          GameTooltip:AddLine("not in bags", C.text3[1], C.text3[2], C.text3[3])
        end
      else
        GameTooltip:ClearLines()
        GameTooltip:AddLine(SETLABEL[this.key] .. " -- " .. HANDNAME[this.hand],
          ahi[1], ahi[2], ahi[3])
        GameTooltip:AddLine("Drop a weapon here", C.text3[1], C.text3[2], C.text3[3])
      end
      GameTooltip:AddLine("Drag: move / drag out: remove", C.text3[1], C.text3[2], C.text3[3])
      GameTooltip:AddLine("Shift-click: clear", C.text3[1], C.text3[2], C.text3[3])
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function()
      this.hover = false
      UpdateSlotHighlights()
      GameTooltip:Hide()
    end)
    table.insert(wslots, b)
    return b
  end

  local function MakeSetRow(key, label, y)
    local lab = menu:CreateFontString(nil, "OVERLAY")
    PB.SetFont(lab, PB.font.normal, 11, "OUTLINE")
    lab:SetPoint("TOPLEFT", menu, "TOPLEFT", 8, y - 7)
    lab:SetText(label)
    lab:SetTextColor(C.text[1], C.text[2], C.text[3])

    MakeWeaponSlot(key, "mh", 74, y)
    MakeWeaponSlot(key, "oh", 102, y)

    local btn = PB.CreateButton(menu, "Use equipped", function()
      local s = PoisonBucketDB.poisonsets[key]
      s.mh = EquippedName(MAINHAND)
      s.oh = EquippedName(OFFHAND)
      s.mhTex = nil                -- repainted from the equipped weapons
      s.ohTex = nil
      RefreshMenu()
      needScan = true
      Check()
    end)
    btn:SetWidth(86)
    btn:SetHeight(18)
    btn:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -8, y - 3)
  end

  MakeSetRow("diss", "Dissolvent", -26)
  MakeSetRow("std", "Standard", -56)

  local autoswapBox = PB.CreateCheckbox(menu, "Auto-swap on new target",
    function() return PoisonBucketDB.poisonAutoswap end,
    function(v) PoisonBucketDB.poisonAutoswap = v and true or false end)
  autoswapBox:SetPoint("TOPLEFT", menu, "TOPLEFT", 8, -88)

  -- drop-target feedback: while ANY drag is live (a real cursor item or a slot
  -- assignment), every socket outlines garnet, the hovered one bright; the
  -- drag's source socket dims instead. With no drag, hover = bright outline.
  UpdateSlotHighlights = function()
    local droppable = (CursorHasItem() or dragInfo) and true or false
    local acc = C.accent
    for i = 1, getn(wslots) do
      local b = wslots[i]
      local isSrc = dragInfo and dragInfo.key == b.key and dragInfo.hand == b.hand
      b.icon:SetAlpha(isSrc and 0.35 or 1)
      if isSrc then
        b.backdrop:SetBackdropBorderColor(0, 0, 0, 1)
      elseif droppable then
        if b.hover then
          b.backdrop:SetBackdropBorderColor(ahi[1], ahi[2], ahi[3], 1)
        else
          b.backdrop:SetBackdropBorderColor(acc[1], acc[2], acc[3], 1)
        end
      elseif b.hover then
        b.backdrop:SetBackdropBorderColor(ahi[1], ahi[2], ahi[3], 1)
      else
        b.backdrop:SetBackdropBorderColor(0, 0, 0, 1)
      end
    end
  end

  -- closing the menu mid-drag drops the drag harmlessly
  menu:SetScript("OnHide", function()
    dragInfo = nil
    dragGhost:Hide()
  end)

  RefreshMenu = function()
    for i = 1, getn(wslots) do
      local b = wslots[i]
      local s = PoisonBucketDB.poisonsets[b.key]
      local name = s[b.hand]
      if name then
        -- refresh the cached icon whenever the weapon is actually findable
        local tex
        local bag, slot = FindInBags(name)
        if bag then
          tex = GetContainerItemInfo(bag, slot)
        elseif EquippedName(MAINHAND) == name then
          tex = GetInventoryItemTexture("player", MAINHAND)
        elseif EquippedName(OFFHAND) == name then
          tex = GetInventoryItemTexture("player", OFFHAND)
        end
        if tex then s[b.hand .. "Tex"] = tex end
        b.icon:SetTexture(s[b.hand .. "Tex"] or "Interface\\Icons\\INV_Sword_04")
        b.icon:Show()
      else
        b.icon:Hide()              -- empty socket: the dark backdrop shows
      end
    end
    autoswapBox.Refresh()
    UpdateSlotHighlights()
  end

  -- ==========================================================================
  -- interaction + the heartbeat / bell driver
  -- ==========================================================================
  chip:SetScript("OnClick", function()
    if CursorHasItem() then TryAddDrop() return end
    if arg1 == "RightButton" then
      if menu:IsShown() then
        menu:Hide()
      else
        RefreshMenu()
        menu:Show()
      end
      return
    end
    PoisonBucketDB.poisonbucketOn = not Armed()
    PaintArmed()
    Check()
  end)
  chip:SetScript("OnReceiveDrag", TryAddDrop)
  -- hover highlight: garnet border while the mouse is over the chip; while
  -- alerting it holds solid (the OnUpdate pulse skips a hovered chip)
  chip:SetScript("OnEnter", function()
    chip.hover = true
    chip.backdrop:SetBackdropBorderColor(ahi[1], ahi[2], ahi[3], 1)
    Tip()
  end)
  chip:SetScript("OnLeave", function()
    chip.hover = false
    if not alerting then chip.backdrop:SetBackdropBorderColor(0, 0, 0, 1) end
    GameTooltip:Hide()
  end)

  -- "lub-dub": two sine pulses (the second softer), then silence for the rest
  local function Envelope(t)
    if t < BEAT then return sin(PI * t / BEAT) end
    t = t - BEAT
    if t < BEAT then return 0.62 * sin(PI * t / BEAT) end
    return 0
  end

  -- charges drain on melee hits with no event, so the state is re-checked on a
  -- 1s poll (same cadence as weaponpoison); the anim math only runs while
  -- alerting / a swap is showing, and bag bursts coalesce through rackDirty
  local acc = 0
  f:SetScript("OnUpdate", function()
    local now = GetTime()
    if alerting then
      local e = Envelope(mod(now - beatStart, PERIOD))
      chip.glow:SetAlpha(e * GLOWMAX)
      if not chip.hover then
        chip.backdrop:SetBackdropBorderColor(ahi[1] * e, ahi[2] * e, ahi[3] * e, 1)
      end
      -- the bell: RING_COUNT rings, RING_GAP apart, restarting every RING_CYCLE
      local el = now - soundAt
      if el >= RING_CYCLE then
        soundAt = now
        el = 0
        rings = 0
      end
      if rings < RING_COUNT and el >= rings * RING_GAP then
        PlaySoundFile(SOUND)
        rings = rings + 1
      end
    end
    if swapNeed then
      local e = Envelope(mod(now - swapStart, PERIOD))
      swapBtn.glow:SetAlpha(e * 0.25)
      swapBtn.backdrop:SetBackdropBorderColor(ahi[1] * e, ahi[2] * e, ahi[3] * e, 1)
    end
    if dragInfo then               -- assignment-drag ghost rides the cursor
      local s = UIParent:GetEffectiveScale()
      local cx, cy = GetCursorPosition()
      dragGhost:ClearAllPoints()
      dragGhost:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx / s + 14, cy / s - 14)
    end
    if rackDirty then
      rackDirty = false
      RepaintRack()
    end
    acc = acc + arg1
    if acc < 1 then return end
    acc = 0
    Check()
  end)

  f:RegisterEvent("PLAYER_ENTERING_WORLD")
  f:RegisterEvent("UNIT_INVENTORY_CHANGED")  -- weapon swap / poison applied
  f:RegisterEvent("PLAYER_TARGET_CHANGED")   -- creature-type swap check
  f:RegisterEvent("BAG_UPDATE")              -- rack counts / icons
  f:RegisterEvent("CURSOR_UPDATE")           -- weapon picked up/dropped: socket glow
  f:RegisterEvent("PLAYER_LOGOUT")
  f:SetScript("OnEvent", function()
    if event == "PLAYER_LOGOUT" then
      this:UnregisterAllEvents()
      this:SetScript("OnEvent", nil)
      this:SetScript("OnUpdate", nil)
      return
    end
    if event == "CURSOR_UPDATE" then
      if menu:IsShown() then UpdateSlotHighlights() end
      return
    end
    if event == "BAG_UPDATE" then
      rackDirty = true
      return
    end
    if event == "UNIT_INVENTORY_CHANGED" or event == "PLAYER_ENTERING_WORLD" then
      needScan = true
      rackDirty = true
    end
    Check()
  end)

  -- position: restored from saved vars; drag the bucket chip to move
  f:SetMovable(true)
  f:SetClampedToScreen(true)
  f:ClearAllPoints()
  local p = PoisonBucketDB.pos
  if p then
    f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
  else
    f:SetPoint("CENTER", UIParent, "CENTER", -60, -230)
  end
  chip:RegisterForDrag("LeftButton")
  chip:SetScript("OnDragStart", function()
    if CursorHasItem() then return end   -- an item drag is a rack drop, not a move
    f:StartMoving()
  end)
  chip:SetScript("OnDragStop", function()
    f:StopMovingOrSizing()
    local point, _, relPoint, x, y = f:GetPoint()
    PoisonBucketDB.pos = { point, relPoint, x, y }
  end)

  PaintArmed()
  RepaintRack()
  Check()
end

-- boot: saved vars are only valid after login; dormant while the full HoryUI
-- addon is loaded (it ships this same module -- running both would double up)
local boot = CreateFrame("Frame")
boot:RegisterEvent("PLAYER_LOGIN")
boot:SetScript("OnEvent", function()
  if IsAddOnLoaded("0HoryUI") then
    DEFAULT_CHAT_FRAME:AddMessage("|cffC8A93EPoison Bucket:|r dormant -- HoryUI is running its own copy.")
    return
  end
  if type(PoisonBucketDB) ~= "table" then PoisonBucketDB = {} end
  local ok, err = pcall(BootPoisonBucket)
  if ok then
    DEFAULT_CHAT_FRAME:AddMessage("|cffC8A93EPoison Bucket|r loaded. Drag the bucket to move it.")
  else
    DEFAULT_CHAT_FRAME:AddMessage("|cffC24450Poison Bucket|r failed: " .. tostring(err))
  end
end)
