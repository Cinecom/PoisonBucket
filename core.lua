-- PoisonBucket :: core -- namespace, Garnet visual tokens, and the tiny widget
-- kit the window needs. Extracted from HoryUI so the addon runs standalone.
-- Lua 5.0 / WoW 1.12 only.

PoisonBucket = PoisonBucket or {}
local PB = PoisonBucket

-- A plain white texture that reliably exists on the 1.12 client.
PB.tex = { white = "Interface\\ChatFrame\\ChatFrameBackground" }

-- "RRGGBB" -> { r, g, b } in 0..1
local function hex(s)
  return {
    tonumber(string.sub(s, 1, 2), 16) / 255,
    tonumber(string.sub(s, 3, 4), 16) / 255,
    tonumber(string.sub(s, 5, 6), 16) / 255,
  }
end

-- Garnet design tokens (the HoryUI look)
PB.color = {
  bg        = hex("0D0E10"),
  text      = hex("F2F2F2"),
  text2     = hex("A8ACB3"),
  text3     = hex("6B7079"),
  accent    = hex("A12E39"),
  accent_hi = hex("C24450"),
  energy    = hex("C8A93E"),
  threat    = hex("D98A2E"),
}
PB.bg_alpha = 0.9

PB.font = {
  normal = "Fonts\\FRIZQT__.TTF",  -- UI / names
  number = "Fonts\\ARIALN.TTF",    -- tabular numbers
}

function PB.SetFont(fs, font, size, flag)
  fs:SetFont(font or PB.font.normal, size or 12, flag or "OUTLINE")
end

-- A near-black panel with a crisp 1px black border, sitting 1px outside `f`.
function PB.CreateBackdrop(f, inset)
  inset = inset or 1
  local b = CreateFrame("Frame", nil, f)
  b:SetPoint("TOPLEFT", f, "TOPLEFT", -inset, inset)
  b:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", inset, -inset)

  local lvl = f:GetFrameLevel() - 1
  if lvl < 0 then lvl = 0 end
  b:SetFrameLevel(lvl)

  b:SetBackdrop({
    bgFile = PB.tex.white,
    edgeFile = PB.tex.white,
    tile = false, tileSize = 0, edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 },
  })

  local bg = PB.color.bg
  b:SetBackdropColor(bg[1], bg[2], bg[3], PB.bg_alpha)
  b:SetBackdropBorderColor(0, 0, 0, 1)

  f.backdrop = b
  return b
end

function PB.CreateButton(parent, label, onclick)
  local b = CreateFrame("Button", nil, parent)
  b:SetWidth(80)
  b:SetHeight(20)
  PB.CreateBackdrop(b)

  b.text = b:CreateFontString(nil, "OVERLAY")
  PB.SetFont(b.text, PB.font.normal, 11, "OUTLINE")
  b.text:SetPoint("CENTER", b, "CENTER", 0, 0)
  b.text:SetText(label)
  local t = PB.color.text
  b.text:SetTextColor(t[1], t[2], t[3])

  b:SetScript("OnEnter", function()
    local a = PB.color.accent_hi
    if this.backdrop then this.backdrop:SetBackdropBorderColor(a[1], a[2], a[3], 1) end
  end)
  b:SetScript("OnLeave", function()
    if this.backdrop then this.backdrop:SetBackdropBorderColor(0, 0, 0, 1) end
  end)
  if onclick then b:SetScript("OnClick", onclick) end
  return b
end

function PB.CreateCheckbox(parent, label, getfn, setfn)
  local row = CreateFrame("Button", nil, parent)
  row:SetHeight(16)
  row:SetWidth(210)

  local box = CreateFrame("Frame", nil, row)
  box:SetWidth(12)
  box:SetHeight(12)
  box:SetPoint("LEFT", row, "LEFT", 0, 0)
  PB.CreateBackdrop(box)

  box.fill = box:CreateTexture(nil, "ARTWORK")
  box.fill:SetTexture(PB.tex.white)
  box.fill:SetPoint("TOPLEFT", box, "TOPLEFT", 3, -3)
  box.fill:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -3, 3)
  local a = PB.color.accent
  box.fill:SetVertexColor(a[1], a[2], a[3], 1)

  row.text = row:CreateFontString(nil, "OVERLAY")
  PB.SetFont(row.text, PB.font.normal, 11, "OUTLINE")
  row.text:SetPoint("LEFT", box, "RIGHT", 6, 0)
  row.text:SetText(label)
  local t = PB.color.text2
  row.text:SetTextColor(t[1], t[2], t[3])

  row.get = getfn
  row.set = setfn
  row.box = box
  row.Refresh = function()
    if row.get() then box.fill:Show() else box.fill:Hide() end
  end
  row:SetScript("OnClick", function()
    row.set(not row.get())
    row.Refresh()
  end)
  row.Refresh()
  return row
end
