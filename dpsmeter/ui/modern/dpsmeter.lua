-- DPS Meter's windows for the Modern pack. The script (../../init.lua) reads the combat lines and keeps the fights;
-- these show them through the script's functions (eq.Plugin("dpsmeter"): state, list, fight, abilities, set, command).
--   The meter (opens with the script; /dps, or the EQ menu's Plugins > DPS Meter): the group's damage per second,
--           a graph of the last 40 seconds, and a bar per player. Fight / Session switches between the fight now
--           (or the last one) and every fight kept. Its height follows the bars it shows (up to the Options' number).
--           Its list button opens the details; a click on a bar opens them on that player.
--           Under the bars: platinum (looted, and sold by NMSloot) and AA gained per hour since the script started (Options can hide it).
--   The details (/dps details): the fights down the left, newest first, with the session at the top. For the chosen
--           one: totals, a graph of damage per second (the group's and the top five's; for the session, a bar per
--           fight), and three tables: damage done (a player's abilities beside it), damage taken, and the mobs.
--           Its gear opens the options.
local hud = dofile("lib/hud.lua")
local T = hud.T
local C = T.color
local DETAILS_KEY = "DpsMeterDetailsWnd"

local P                    -- the script's functions (nil while it is not running)
local st = {}              -- its state, read each frame
local DOT = "  \xC2\xB7  "

-- ---------------------------------------------------------------- formats and colours

local function fmt(n)
  n = tonumber(n) or 0
  local a = math.abs(n)
  if a >= 1e6 then return string.format("%.2fM", n / 1e6) end
  if a >= 1e4 then return string.format("%.1fk", n / 1e3) end
  return T.Thousands(n)
end

local function clock(sec)
  sec = math.floor((tonumber(sec) or 0) + 0.5)
  if sec >= 3600 then return string.format("%d:%02d:%02d", sec // 3600, (sec % 3600) // 60, sec % 60) end
  return string.format("%d:%02d", sec // 60, sec % 60)
end

local function pct(v) return string.format("%.0f%%", tonumber(v) or 0) end

-- Platinum: tenths while it is small. AA: hundredths.
local function plat(v)
  v = tonumber(v) or 0
  if v < 100 then return (string.format("%.1f", v):gsub("%.0$", "")) end
  return fmt(v)
end
local function aa(v) return string.format("%.2f", tonumber(v) or 0) end

-- A colour and a short name per class (by class id), for bars, lines and the class tags.
local CLASS = {
  [1] = { "WAR", { 0.82, 0.58, 0.40 } }, [2] = { "CLR", { 0.92, 0.90, 0.80 } }, [3] = { "PAL", { 0.98, 0.80, 0.40 } },
  [4] = { "RNG", { 0.48, 0.80, 0.40 } }, [5] = { "SHD", { 0.62, 0.40, 0.86 } }, [6] = { "DRU", { 0.98, 0.58, 0.22 } },
  [7] = { "MNK", { 0.30, 0.86, 0.74 } }, [8] = { "BRD", { 0.96, 0.48, 0.68 } }, [9] = { "ROG", { 0.96, 0.92, 0.48 } },
  [10] = { "SHM", { 0.32, 0.60, 0.98 } }, [11] = { "NEC", { 0.62, 0.82, 0.36 } }, [12] = { "WIZ", { 0.42, 0.82, 1.00 } },
  [13] = { "MAG", { 1.00, 0.44, 0.34 } }, [14] = { "ENC", { 0.78, 0.60, 1.00 } }, [15] = { "BST", { 0.74, 0.54, 0.34 } },
  [16] = { "BER", { 0.92, 0.28, 0.34 } },
}
local function classColor(id)
  local c = CLASS[tonumber(id) or 0]
  return c and c[2] or C.accent
end
local function className(id)
  local c = CLASS[tonumber(id) or 0]
  return c and c[1] or nil
end

local KIND_COLOR = { melee = { 0.95, 0.70, 0.40 }, spell = { 0.48, 0.70, 1.00 }, dot = { 0.62, 0.86, 0.40 },
  ds = { 0.86, 0.60, 1.00 } }

-- ---------------------------------------------------------------- pieces

-- A bar in a colour, as the HUD's bars are drawn: a darker body, a lighter top, a sheen.
local function fillBar(x0, y0, x1, y1, col, s, alpha)
  alpha = alpha or 1
  if x1 - x0 < 1 then return end
  local h = y1 - y0
  local rad = math.min(4 * s, h / 2, (x1 - x0) / 2)
  ui.DrawRectFilled(x0, y0, x1, y1, col[1] * 0.55, col[2] * 0.55, col[3] * 0.55, 0.92 * alpha, rad)
  ui.DrawRectFilled(x0, y0, x1, y0 + h * 0.6, col[1] * 0.85, col[2] * 0.85, col[3] * 0.85, 0.92 * alpha, rad)
  ui.DrawRectFilled(x0 + 1, y0 + 1, x1 - 1, y0 + math.max(1, h * 0.2), 1, 1, 1, 0.16 * alpha, rad)
end

-- A small rounded tag, as a class short name: its colour, text in it. Returns its width.
local function tag(x, y, text, col, s)
  local tw, th = T.TextSize(text, T.font.tiny)
  local w, h = tw + 8 * s, th + 2 * s
  ui.DrawRectFilled(x, y, x + w, y + h, col[1], col[2], col[3], 0.20, 3 * s)
  ui.DrawRect(x, y, x + w, y + h, col[1], col[2], col[3], 0.45, 3 * s, 1)
  T.Text(x + 4 * s, y + 1 * s, text, col, T.font.tiny)
  return w
end

-- A row of pills, one chosen (list = { {id, label}, ... }). Returns the id clicked.
local function segmented(id, x0, y0, x1, y1, s, list, current, font)
  local n = #list
  local gap = 3 * s
  local w = (x1 - x0 - gap * (n - 1)) / n
  local rad = (y1 - y0) / 2
  local clicked = nil
  ui.DrawRectFilled(x0 - 2 * s, y0 - 2 * s, x1 + 2 * s, y1 + 2 * s, C.inset[1], C.inset[2], C.inset[3], C.inset[4],
    rad + 2 * s)
  font = font or T.font.small
  local _, th = T.TextSize("Ag", font)
  for i, e in ipairs(list) do
    local bx0 = x0 + (i - 1) * (w + gap)
    local bx1 = bx0 + w
    local hit = T.Hit(id .. e[1], bx0, y0, bx1, y1)
    local hovered = ui.IsItemHovered()
    local on = e[1] == current
    local a = C.accent
    if on then
      ui.DrawRectFilled(bx0, y0, bx1, y1, a[1], a[2], a[3], 0.28, rad)
      ui.DrawRect(bx0, y0, bx1, y1, a[1], a[2], a[3], 0.80, rad, 1.2 * s)
    elseif hovered then
      ui.DrawRectFilled(bx0, y0, bx1, y1, C.ink[1], C.ink[2], C.ink[3], 0.07, rad)
    end
    T.Text((bx0 + bx1) / 2, y0 + (y1 - y0 - th) / 2, e[2], on and C.text or C.muted, font, "center")
    if hovered and e[3] then ui.SetTooltip(e[3]) end
    if hit and not on then clicked = e[1] end
  end
  return clicked
end

-- An icon button (a square with a hover fill). draw(cx, cy, size, colour) draws the icon. Returns clicked.
local function iconButton(id, x, y, size, s, lit, tipText, draw)
  local clicked = T.Hit(id, x, y, x + size, y + size)
  local hovered, active = ui.IsItemHovered(), ui.IsItemActive()
  if hovered or lit then
    local a = lit and C.accent or C.ink
    ui.DrawRectFilled(x, y, x + size, y + size, a[1], a[2], a[3],
      lit and (hovered and 0.35 or 0.25) or (active and 0.16 or 0.10), size / 4)
  end
  draw(x + size / 2, y + size / 2, size, (hovered or lit) and C.text or C.muted)
  if hovered and tipText then ui.SetTooltip(tipText) end
  return clicked
end

local function listIcon(cx, cy, size, c)
  local w, g = size * 0.30, size * 0.20
  for k = -1, 1 do
    local y = cy + k * g
    ui.DrawCircleFilled(cx - w - size * 0.06, y, size * 0.055, c[1], c[2], c[3], 1)
    ui.DrawLine(cx - w + size * 0.08, y, cx + w, y, c[1], c[2], c[3], 1, size * 0.09)
  end
end

local function gearIcon(cx, cy, size, c)
  local r = size * 0.22
  for k = 0, 7 do
    local ang = k * math.pi / 4
    local dx, dy = math.cos(ang), math.sin(ang)
    ui.DrawLine(cx + dx * r, cy + dy * r, cx + dx * (r + size * 0.14), cy + dy * (r + size * 0.14), c[1], c[2], c[3], 1,
      size * 0.12)
  end
  ui.DrawCircle(cx, cy, r, c[1], c[2], c[3], 1, size * 0.10)
end

-- A soft pulsing dot: live (green) or idle (faint).
local function liveDot(cx, cy, s, live)
  local c = live and { 0.36, 0.86, 0.50, 1 } or C.faint
  if live then
    local glow = 0.25 + 0.20 * math.sin(ui.GetTime() * 4)
    ui.DrawCircleFilled(cx, cy, 7 * s, c[1], c[2], c[3], glow)
  end
  ui.DrawCircleFilled(cx, cy, 3.5 * s, c[1], c[2], c[3], 1)
end

-- Damage per second, second by second, as columns with a smoothed line over them. values: damage per second.
local function sparkline(x0, y0, x1, y1, values, s, slots)
  local n = #values
  ui.DrawRectFilled(x0, y0, x1, y1, C.inset[1], C.inset[2], C.inset[3], C.inset[4] * 0.7, 4 * s)
  if n == 0 then return end
  slots = slots or n
  local top = 1
  for _, v in ipairs(values) do if v > top then top = v end end
  local pad = 2 * s
  local h = y1 - y0 - pad * 2
  local cw = (x1 - x0 - pad * 2) / slots
  local a = C.accent
  local start = x1 - pad - n * cw
  local pts = {}
  for i, v in ipairs(values) do
    local bx = start + (i - 1) * cw
    local by = y1 - pad - (v / top) * h
    if v > 0 then
      ui.DrawRectGradient(bx + 0.5, by, bx + math.max(1, cw - 1), y1 - pad, a[1], a[2], a[3], 0.55, a[1], a[2], a[3], 0.10)
    end
    -- three-second average, for the line
    local sum, k = 0, 0
    for j = math.max(1, i - 2), i do sum, k = sum + values[j], k + 1 end
    pts[i] = { bx + cw / 2, y1 - pad - (sum / k / top) * h }
  end
  for i = 2, #pts do
    ui.DrawLine(pts[i - 1][1], pts[i - 1][2], pts[i][1], pts[i][2], a[1], a[2], a[3], 0.95, 1.5 * s)
  end
end

-- ---------------------------------------------------------------- the details' selection (shared with the meter)

local sel = { fight = nil, actor = nil, tab = "done", page = "fight" }
local cache = { list = {}, fight = nil, abilities = {}, rev = -1, fightKey = nil, abKey = nil, at = -1 }

local function openDetails(fightId, actor)
  if not st.details_open then P.command("details") end
  sel.page = "fight"
  if fightId then sel.fight = fightId end
  if actor then sel.actor = actor sel.tab = "done" end
end

-- ---------------------------------------------------------------- the meter

local ROW_H = 22

-- The meter's height follows what it shows: no empty space under the bars, room for each new player. It eases to a
-- new height (the bars are clipped to the panel meanwhile) instead of jumping.
local shownH = nil
local lastT = nil

local RATES_H = 28 -- the platinum and AA strip under the bars

local function targetHeight()
  local extra = (st.settings and st.settings.show_rates ~= false) and RATES_H or 0
  if not st.fight then return 92 + extra end
  return 104 + #(st.rows or {}) * (ROW_H + 3) + extra
end

local function compactSize(s)
  local want = targetHeight()
  local t = ui.GetTime()
  local dt = lastT and math.max(0, math.min(t - lastT, 0.1)) or 0
  lastT = t
  if not shownH then shownH = want end
  shownH = shownH + (want - shownH) * math.min(1, dt * 12)
  if math.abs(want - shownH) < 0.5 then shownH = want end
  return 300, shownH
end

local VIEWS = { { "fight", "Fight", "The fight now, or the last one" }, { "session", "Session", "Every fight kept, added up" } }

local function meterRow(i, r, x0, y0, x1, y1, s, top, fightId)
  local hit = T.Hit("##dpsrow" .. i, x0, y0, x1, y1)
  local hovered = ui.IsItemHovered()
  local col = classColor(r.class)
  local rad = 4 * s
  ui.DrawRectFilled(x0, y0, x1, y1, C.inset[1], C.inset[2], C.inset[3], C.inset[4] * 0.8, rad)
  fillBar(x0, y0, x0 + (x1 - x0) * math.max(0.012, r.value / top), y1, col, s, hovered and 1 or 0.9)
  if r.name == st.me then ui.DrawRect(x0, y0, x1, y1, C.accent[1], C.accent[2], C.accent[3], 0.55, rad, 1.2 * s) end
  if hovered then ui.DrawRect(x0, y0, x1, y1, C.ink[1], C.ink[2], C.ink[3], 0.35, rad, 1) end
  local _, th = T.TextSize("Ag", T.font.small)
  local ty = y0 + (y1 - y0 - th) / 2
  local right = fmt(r.dps) .. "  " .. fmt(r.value) .. "  " .. pct(r.pct)
  local rw = T.TextSize(right, T.font.small)
  T.Text(x0 + 6 * s, ty, tostring(i), C.barText, T.font.tiny, nil, 0.7, C.barShadow)
  T.Text(x0 + 18 * s, ty, T.Fit(r.name, x1 - x0 - rw - 32 * s, T.font.small), C.barText, T.font.small, nil, 1, C.barShadow)
  T.Text(x1 - 6 * s, ty, right, C.barText, T.font.small, "right", 1, C.barShadow)
  if hovered then
    ui.SetTooltip(string.format("%s%s\n%s damage (%s)  %s dps\n%d hits%s  %d crits  biggest %s%s\nClick for the details",
      r.name, className(r.class) and ("  " .. className(r.class)) or "", T.Thousands(r.value), pct(r.pct), fmt(r.dps),
      r.hits, r.accuracy and string.format(" (%.0f%% hit)", r.accuracy) or "", r.crits, T.Thousands(r.max),
      (r.pet or 0) > 0 and ("\nPet: " .. T.Thousands(r.pet)) or ""))
  end
  if hit then openDetails(fightId, r.name) end
end

-- A coin: platinum's colour, a rim and a glint.
local function coinIcon(cx, cy, r)
  local c = C.platinum or { 0.85, 0.88, 0.95, 1 }
  ui.DrawCircleFilled(cx, cy, r, c[1] * 0.55, c[2] * 0.55, c[3] * 0.6, 1)
  ui.DrawCircleFilled(cx, cy, r * 0.78, c[1], c[2], c[3], 1)
  ui.DrawCircleFilled(cx - r * 0.25, cy - r * 0.25, r * 0.22, 1, 1, 1, 0.75)
end

-- Platinum and AA per hour, in a strip at the meter's foot. Its tooltip has the totals and since when.
local function ratesStrip(x0, y0, x1, y1, s)
  local r = st.rates
  if not r then return end
  ui.DrawRectFilled(x0, y0, x1, y1, C.inset[1], C.inset[2], C.inset[3], C.inset[4] * 0.7, 4 * s)
  local mid = (x0 + x1) / 2
  ui.DrawLine(mid, y0 + 5 * s, mid, y1 - 5 * s, C.ink[1], C.ink[2], C.ink[3], 0.08, 1)
  local _, th = T.TextSize("Ag", T.font.small)
  local ty = y0 + (y1 - y0 - th) / 2
  local cy = (y0 + y1) / 2
  coinIcon(x0 + 14 * s, cy, 6 * s)
  local pw = T.Text(x0 + 26 * s, ty, r.plat_hour and plat(r.plat_hour) or plat(r.plat), r.plat_hour and C.text or C.muted,
    T.font.small)
  T.Text(x0 + 30 * s + pw, ty + 1 * s, r.plat_hour and "pp / hour" or "pp so far", C.faint, T.font.tiny)
  local aac = C.aa or C.gold
  local tw = tag(mid + 10 * s, cy - 7 * s, "AA", aac, s)
  local aw = T.Text(mid + 16 * s + tw, ty, r.aa_hour and aa(r.aa_hour) or aa(r.aa), r.aa_hour and C.text or C.muted,
    T.font.small)
  T.Text(mid + 20 * s + tw + aw, ty + 1 * s, r.aa_hour and "AA / hour" or "AA so far", C.faint, T.font.tiny)
  if ui.IsMouseHoveringRect(x0, y0, x1, y1) then
    local coin = string.format("%s platinum: %s looted (%d corpses and splits)", plat(r.plat), plat(r.looted), r.loots)
    if (r.sales or 0) > 0 then coin = coin .. string.format(", %s sold by NMSloot (%d items)", plat(r.sold), r.sales) end
    ui.SetTooltip(string.format("Since %s (%s)\n%s\n%s AA gained%s\n/dps reset starts again from now", r.since,
      clock(r.seconds), coin, aa(r.aa), r.plat_hour and "" or "\n(a rate per hour after the first minute)"))
  end
end

local function meter(x, y, w, h, s)
  local pad = 10 * s
  local f = st.fight
  -- the title row: a live light, the name, Fight / Session and the details button (the close X is the frame's)
  liveDot(x + pad + 4 * s, y + 14 * s, s, st.fighting)
  T.Text(x + pad + 14 * s, y + 7 * s, "DPS METER", C.muted, T.font.small)
  if iconButton("##dpsdetails", x + w - 44 * s, y + 4 * s, 18 * s, s, st.details_open, "Fights and details (/dps details)",
        listIcon) then
    P.command("details")
  end
  local v = segmented("##dpsview", x + w - 160 * s, y + 6 * s, x + w - 52 * s, y + 20 * s, s, VIEWS,
    st.settings and st.settings.view or "fight", T.font.tiny)
  if v then P.set("view", v) end

  -- the rate, and what the fight is
  local yy = y + 28 * s
  if not f then
    T.Text(x + w / 2, y + 36 * s, "No fights yet", C.muted, T.font.normal, "center")
    T.Text(x + w / 2, y + 56 * s, "Hit something and the damage shows here.", C.faint, T.font.small, "center")
    if st.settings and st.settings.show_rates ~= false then
      ratesStrip(x + pad, y + h - pad - (RATES_H - 6) * s, x + w - pad, y + h - pad, s)
    end
    return
  end
  local big = fmt(f.dps)
  local bw, bh = T.TextSize(big, T.font.large)
  T.Text(x + pad, yy, big, C.text, T.font.large)
  T.Text(x + pad + bw + 4 * s, yy + bh - 13 * s, "dps", C.muted, T.font.small)
  local nameW = w - pad * 2 - bw - 40 * s
  local name = f.name .. ((f.extra or 0) > 0 and (" +" .. f.extra) or "")
  T.Text(x + w - pad, yy, T.Fit(name, nameW, T.font.normal), C.text, T.font.normal, "right")
  local sub
  if f.id == 0 then
    sub = (f.count or 0) .. " fights" .. DOT .. clock(f.duration) .. DOT .. fmt(f.total)
  else
    sub = (f.live and "LIVE  " or "") .. clock(f.duration) .. DOT .. fmt(f.total)
      .. ((f.kills or 0) > 0 and (DOT .. f.kills .. (f.kills == 1 and " kill" or " kills")) or "")
  end
  T.Text(x + w - pad, yy + 18 * s, sub, f.live and { 0.40, 0.88, 0.55, 1 } or C.faint, T.font.small, "right")

  -- the last 40 seconds (none for the session)
  yy = yy + 40 * s
  if st.spark then
    sparkline(x + pad, yy, x + w - pad, yy + 22 * s, st.spark, s, 40)
  else
    ui.DrawRectFilled(x + pad, yy, x + w - pad, yy + 22 * s, C.inset[1], C.inset[2], C.inset[3], C.inset[4] * 0.7, 4 * s)
    local you = 0
    for _, r in ipairs(st.rows or {}) do if r.name == st.me then you = r.dps end end
    T.Text(x + w / 2, yy + 5 * s, "Your average " .. fmt(you) .. " dps over " .. clock(f.duration) .. " of fighting",
      C.muted, T.font.small, "center")
  end
  yy = yy + 30 * s

  -- a bar per player
  local rows = st.rows or {}
  local top = rows[1] and math.max(1, rows[1].value) or 1
  local showRates = st.settings and st.settings.show_rates ~= false
  local barsEnd = y + h - (showRates and RATES_H * s or 0)
  ui.PushClipRect(x, y, x + w, barsEnd, true) -- (while the window grows to a new bar)
  for i, r in ipairs(rows) do
    if yy < barsEnd then meterRow(i, r, x + pad, yy, x + w - pad, yy + ROW_H * s, s, top, f.id) end
    yy = yy + (ROW_H + 3) * s
  end
  ui.PopClipRect()
  if showRates then ratesStrip(x + pad, y + h - pad - (RATES_H - 6) * s, x + w - pad, y + h - pad, s) end
end

-- ---------------------------------------------------------------- the details: tables

-- A table drawn in the meter's look. cols = { {title, width (0: takes the rest), align, cell(row) -> text, colour} };
-- opts: selected(row) -> bool, onClick(row), bar(row) -> fraction and colour, tip(row) -> text, empty. Scrolls.
local function table_(id, x, y, w, h, s, rows, cols, opts)
  opts = opts or {}
  local headH, rowH = 20 * s, 24 * s
  local fixed, flex = 0, 0
  for _, c in ipairs(cols) do
    if c[2] > 0 then fixed = fixed + c[2] * s else flex = flex + 1 end
  end
  local xs, cx = {}, x + 8 * s
  for i, c in ipairs(cols) do
    local cw = c[2] > 0 and c[2] * s or math.max(40 * s, (w - 16 * s - fixed) / math.max(1, flex))
    xs[i] = { cx, cx + cw }
    cx = cx + cw
  end
  -- the header
  ui.DrawRectFilled(x, y, x + w, y + h, C.inset[1], C.inset[2], C.inset[3], C.inset[4] * 0.5, 6 * s)
  local _, th = T.TextSize("Ag", T.font.tiny)
  for i, c in ipairs(cols) do
    local tx = c[3] == "right" and xs[i][2] - 4 * s or xs[i][1] + 4 * s
    T.Text(tx, y + (headH - th) / 2, c[1]:upper(), C.faint, T.font.tiny, c[3] == "right" and "right" or nil)
  end
  ui.DrawLine(x + 6 * s, y + headH, x + w - 6 * s, y + headH, C.ink[1], C.ink[2], C.ink[3], 0.08, 1)
  -- the rows, in a child that scrolls
  ui.SetCursorScreenPos(x, y + headH + 1)
  ui.BeginChild(id, w, h - headH - 2, false, ui.WindowFlags.NoBackground)
  local top = select(2, ui.GetCursorScreenPos())
  local _, rth = T.TextSize("Ag", T.font.small)
  if #rows == 0 and opts.empty then
    T.Text(x + w / 2, top + 16 * s, opts.empty, C.faint, T.font.small, "center")
  end
  for i, r in ipairs(rows) do
    local y0 = top + (i - 1) * rowH
    local y1 = y0 + rowH
    local clicked = T.Hit(id .. "r" .. i, x + 2 * s, y0, x + w - 2 * s, y1 - 1)
    local hovered = ui.IsItemHovered()
    local on = opts.selected and opts.selected(r)
    if i % 2 == 0 then ui.DrawRectFilled(x + 2 * s, y0, x + w - 2 * s, y1, C.ink[1], C.ink[2], C.ink[3], 0.025, 4 * s) end
    if opts.bar then
      local frac, col = opts.bar(r)
      if frac and frac > 0 then
        ui.DrawRectGradient(x + 2 * s, y0 + 2 * s, x + 2 * s + (w - 4 * s) * math.min(1, frac), y1 - 2 * s,
          col[1], col[2], col[3], 0.22, col[1], col[2], col[3], 0.10)
      end
    end
    if on then
      local a = C.accent
      ui.DrawRectFilled(x + 2 * s, y0, x + w - 2 * s, y1, a[1], a[2], a[3], 0.12, 4 * s)
      ui.DrawRectFilled(x + 2 * s, y0 + 4 * s, x + 5 * s, y1 - 4 * s, a[1], a[2], a[3], 1, 2 * s)
    elseif hovered and opts.onClick then
      ui.DrawRectFilled(x + 2 * s, y0, x + w - 2 * s, y1, C.ink[1], C.ink[2], C.ink[3], 0.06, 4 * s)
    end
    local ty = y0 + (rowH - rth) / 2
    for k, c in ipairs(cols) do
      local x0, x1 = xs[k][1] + 4 * s, xs[k][2] - 4 * s
      local text, col, pre = c[4](r)
      if pre then x0 = x0 + pre(x0, y0, rowH) end
      text = T.Fit(tostring(text or ""), x1 - x0, T.font.small)
      T.Text(c[3] == "right" and x1 or x0, ty, text, col or (k == 1 and C.text or C.muted), T.font.small,
        c[3] == "right" and "right" or nil)
    end
    if hovered and opts.tip then
      local t = opts.tip(r)
      if t then ui.SetTooltip(t) end
    end
    if clicked and opts.onClick then opts.onClick(r) end
  end
  ui.SetCursorScreenPos(x, top + #rows * rowH)
  ui.Dummy(1, 4 * s)
  ui.EndChild()
end

local scale = 1 -- the details' scale this frame (for cells, which are not given it)

-- The name cell: a class tag before the name.
local function nameCell(r)
  local cls = className(r.class)
  return r.name, r.name == st.me and C.accent or C.text, cls and function(x0, y0, rowH)
    local _, th = T.TextSize("Ag", T.font.tiny)
    return tag(x0, y0 + (rowH - th - 2 * scale) / 2, cls, classColor(r.class), scale) + 6 * scale
  end or nil
end

-- ---------------------------------------------------------------- the details: graph

local function smooth(list, n, k)
  local out = {}
  local sum = 0
  for i = 1, n do
    sum = sum + (list[i] or 0)
    if i > k then sum = sum - (list[i - k] or 0) end
    out[i] = sum / math.min(i, k)
  end
  return out
end

-- Lines for players whose class is not known (a player who left the zone).
local SERIES = { { 1, 0.80, 0.36 }, { 0.40, 0.88, 0.55 }, { 0.96, 0.48, 0.68 }, { 0.78, 0.60, 1.00 }, { 1, 0.55, 0.30 } }

local function graphFrame(x0, y0, x1, y1, s)
  ui.DrawRectFilled(x0, y0, x1, y1, C.inset[1], C.inset[2], C.inset[3], C.inset[4] * 0.6, 6 * s)
  ui.DrawRect(x0, y0, x1, y1, C.ink[1], C.ink[2], C.ink[3], 0.06, 6 * s, 1)
end

-- Damage per second over the fight: the group's as a filled area, the top five as lines; hover reads a second.
local function fightGraph(fd, x0, y0, x1, y1, s)
  graphFrame(x0, y0, x1, y1, s)
  local n = #fd.timeline
  if fd.head.live then n = math.max(n, math.floor(fd.head.duration + 0.5)) end
  if n < 2 then
    T.Text((x0 + x1) / 2, (y0 + y1) / 2 - 7 * s, "The graph fills in as the fight goes on", C.faint, T.font.small, "center")
    return
  end
  local K = n > 120 and 10 or 5
  local total = smooth(fd.timeline, n, K)
  local top = 1
  for i = 1, n do if total[i] > top then top = total[i] end end
  top = top * 1.1
  local gx0, gy0, gx1, gy1 = x0 + 10 * s, y0 + 22 * s, x1 - 50 * s, y1 - 18 * s
  local function px(i) return gx0 + (i - 1) / (n - 1) * (gx1 - gx0) end
  local function py(v) return gy1 - v / top * (gy1 - gy0) end
  -- grid and labels
  for k = 0, 3 do
    local v = top * k / 3
    local y = py(v)
    ui.DrawLine(gx0, y, gx1, y, C.ink[1], C.ink[2], C.ink[3], k == 0 and 0.12 or 0.05, 1)
    if k > 0 then T.Text(gx1 + 6 * s, y - 6 * s, fmt(v), C.faint, T.font.tiny) end
  end
  for k = 0, 4 do
    local i = 1 + math.floor((n - 1) * k / 4 + 0.5)
    T.Text(px(i), gy1 + 3 * s, clock(i - 1), C.faint, T.font.tiny, k == 0 and nil or (k == 4 and "right" or "center"))
  end
  -- the group's area and line
  local a = C.accent
  local step = math.max(1, math.floor(n / math.max(1, (gx1 - gx0) / (2 * s))))
  for i = 1, n - 1, step do
    local j = math.min(n, i + step)
    local xa, xb = px(i), px(j)
    local ya = math.min(py(total[i]), py(total[j]))
    ui.DrawRectGradient(xa, ya, xb + 0.5, gy1, a[1], a[2], a[3], 0.30, a[1], a[2], a[3], 0.03)
  end
  for i = 1 + step, n, step do
    ui.DrawLine(px(i - step), py(total[i - step]), px(i), py(total[i]), a[1], a[2], a[3], 1, 2 * s)
  end
  -- each of the top five
  local smoothed = {}
  for si, series in ipairs(fd.series or {}) do
    local col = CLASS[tonumber(series.class) or 0] and classColor(series.class) or SERIES[si]
    local line = smooth(series.timeline, n, K)
    smoothed[si] = { name = series.name, col = col, line = line }
    for i = 1 + step, n, step do
      ui.DrawLine(px(i - step), py(line[i - step]), px(i), py(line[i]), col[1], col[2], col[3], 0.85, 1.4 * s)
    end
  end
  -- the legend
  local lx = x0 + 10 * s
  T.Text(lx, y0 + 5 * s, "DAMAGE PER SECOND", C.faint, T.font.tiny)
  lx = lx + T.TextSize("DAMAGE PER SECOND", T.font.tiny) + 14 * s
  local function key(name, col)
    ui.DrawRectFilled(lx, y0 + 9 * s, lx + 10 * s, y0 + 11 * s, col[1], col[2], col[3], 1, 1 * s)
    local tw = T.Text(lx + 14 * s, y0 + 4 * s, name, C.muted, T.font.tiny)
    lx = lx + tw + 26 * s
  end
  key("Group", C.accent)
  for _, sm in ipairs(smoothed) do if lx < x1 - 80 * s then key(sm.name, sm.col) end end
  -- hover: the second under the mouse
  if ui.IsMouseHoveringRect(gx0, y0, gx1, y1) then
    local mx = ui.GetMousePos()
    local i = math.max(1, math.min(n, math.floor((mx - gx0) / (gx1 - gx0) * (n - 1) + 1.5)))
    local hx = px(i)
    ui.DrawLine(hx, gy0, hx, gy1, C.ink[1], C.ink[2], C.ink[3], 0.35, 1)
    ui.DrawCircleFilled(hx, py(total[i]), 3.5 * s, a[1], a[2], a[3], 1)
    local lines = { clock(i - 1) .. "   group " .. fmt(total[i]) .. " dps" }
    for _, sm in ipairs(smoothed) do
      ui.DrawCircleFilled(hx, py(sm.line[i]), 2.5 * s, sm.col[1], sm.col[2], sm.col[3], 1)
      lines[#lines + 1] = sm.name .. "   " .. fmt(sm.line[i])
    end
    ui.SetTooltip(table.concat(lines, "\n") .. "\n(" .. K .. "-second average)")
  end
end

-- The session: a bar per fight, oldest at the left; a click opens that fight.
local function sessionGraph(list, x0, y0, x1, y1, s)
  graphFrame(x0, y0, x1, y1, s)
  T.Text(x0 + 10 * s, y0 + 5 * s, "DPS PER FIGHT", C.faint, T.font.tiny)
  local fs = {}
  for i = #list, 1, -1 do if list[i].id ~= 0 then fs[#fs + 1] = list[i] end end
  if #fs == 0 then return end
  local top = 1
  for _, f in ipairs(fs) do if f.dps > top then top = f.dps end end
  top = top * 1.1
  local gx0, gy0, gx1, gy1 = x0 + 10 * s, y0 + 22 * s, x1 - 50 * s, y1 - 10 * s
  for k = 1, 3 do
    local y = gy1 - (gy1 - gy0) * k / 3
    ui.DrawLine(gx0, y, gx1, y, C.ink[1], C.ink[2], C.ink[3], 0.05, 1)
    T.Text(gx1 + 6 * s, y - 6 * s, fmt(top * k / 3), C.faint, T.font.tiny)
  end
  local slot = (gx1 - gx0) / math.max(#fs, 8)
  local bw = math.max(3 * s, math.min(slot * 0.7, 28 * s))
  for i, f in ipairs(fs) do
    local cx = gx0 + (i - 0.5) * slot
    local by = gy1 - f.dps / top * (gy1 - gy0)
    local hit = T.Hit("##dpssg" .. f.id, cx - slot / 2, gy0, cx + slot / 2, gy1)
    local hovered = ui.IsItemHovered()
    local col = f.live and { 0.40, 0.88, 0.55 } or C.accent
    ui.DrawRectGradient(cx - bw / 2, by, cx + bw / 2, gy1, col[1], col[2], col[3], hovered and 0.95 or 0.70,
      col[1], col[2], col[3], 0.20)
    ui.DrawRectFilled(cx - bw / 2, by, cx + bw / 2, by + 2 * s, col[1], col[2], col[3], 1, 1 * s)
    if hovered then
      ui.SetTooltip(string.format("%s%s\n%s dps%s%s%s%s\nClick to open it", f.name,
        (f.extra or 0) > 0 and (" +" .. f.extra) or "", fmt(f.dps), DOT, clock(f.duration), DOT, f.when))
    end
    if hit then sel.fight = f.id end
  end
end

-- ---------------------------------------------------------------- the details: pages

local TABS = { { "done", "Damage done" }, { "taken", "Damage taken" }, { "mobs", "Mobs" } }

-- A totals tile: a caption, a big number, a line under it.
local function tile(x0, y0, x1, y1, s, caption, value, sub, col)
  ui.DrawRectFilled(x0, y0, x1, y1, C.inset[1], C.inset[2], C.inset[3], C.inset[4] * 0.6, 6 * s)
  if col then ui.DrawRectFilled(x0, y0 + 8 * s, x0 + 3 * s, y1 - 8 * s, col[1], col[2], col[3], 0.9, 2 * s) end
  T.Text(x0 + 12 * s, y0 + 7 * s, caption, C.faint, T.font.tiny)
  T.Text(x0 + 12 * s, y0 + 19 * s, value, C.text, T.font.large)
  if sub then T.Text(x1 - 10 * s, y0 + 9 * s, sub, C.muted, T.font.tiny, "right") end
end

local function abilityPanel(x, y, w, h, s, fd)
  local who
  for _, r in ipairs(fd.damage) do if r.name == sel.actor then who = r end end
  ui.DrawRectFilled(x, y, x + w, y + h, C.inset[1], C.inset[2], C.inset[3], C.inset[4] * 0.5, 6 * s)
  if not who then
    T.Text(x + w / 2, y + h / 2 - 7 * s, "Pick a player to see their abilities", C.faint, T.font.small, "center")
    return
  end
  local col = classColor(who.class)
  ui.DrawRectFilled(x + 10 * s, y + 12 * s, x + 13 * s, y + 40 * s, col[1], col[2], col[3], 1, 2 * s)
  T.Text(x + 20 * s, y + 9 * s, T.Fit(who.name, w - 30 * s, T.font.normal), C.text, T.font.normal)
  local facts = { who.hits .. " hits" }
  if who.accuracy then facts[#facts + 1] = string.format("%.0f%% hit", who.accuracy) end
  facts[#facts + 1] = who.crits .. " crits"
  if (who.max or 0) > 0 then facts[#facts + 1] = "biggest " .. fmt(who.max) end
  if (who.pet or 0) > 0 and who.damage > 0 then facts[#facts + 1] = "pet " .. pct(who.pet / who.damage * 100) end
  T.Text(x + 20 * s, y + 27 * s, T.Fit(table.concat(facts, DOT), w - 30 * s, T.font.tiny), C.muted, T.font.tiny)
  local ab = cache.abilities
  local topAb = ab[1] and ab[1].damage or 1
  table_("##dpsab", x + 4 * s, y + 48 * s, w - 8 * s, h - 52 * s, s, ab, {
    { "Ability", 0, nil, function(r) return r.name, C.text end },
    { "Damage", 60, "right", function(r) return fmt(r.damage), C.text end },
    { "%", 40, "right", function(r) return pct(r.pct) end },
    { "Hits", 40, "right", function(r) return tostring(r.hits) end },
  }, {
    bar = function(r) return r.damage / topAb, KIND_COLOR[r.kind] or C.accent end,
    tip = function(r)
      return string.format("%s\n%s damage in %d hits, %s on average, %s at most", r.name, T.Thousands(r.damage),
        r.hits, fmt(r.avg), T.Thousands(r.max))
    end,
    empty = "No damage",
  })
end

local function fightPage(x, y, w, h, s)
  local fd = cache.fight
  if not fd then
    T.Text(x + w / 2, y + h / 2 - 20 * s, "No fights yet", C.muted, T.font.large, "center")
    T.Text(x + w / 2, y + h / 2 + 6 * s, "Fights show here as you have them, newest first.", C.faint, T.font.small, "center")
    return
  end
  local hd = fd.head
  -- the title, what and when, and a button
  local _, th = T.TextSize("Ag", T.font.large)
  local title = hd.name .. ((hd.extra or 0) > 0 and ("  +" .. hd.extra .. " more") or "")
  T.Text(x, y, T.Fit(title, w - 120 * s, T.font.large), C.text, T.font.large)
  local bits = {}
  if hd.id == 0 then
    bits[#bits + 1] = (hd.count or 0) .. " fights"
    bits[#bits + 1] = clock(hd.duration) .. " of fighting"
  else
    if hd.zone ~= "" then bits[#bits + 1] = hd.zone end
    if hd.when ~= "" then bits[#bits + 1] = hd.when end
    bits[#bits + 1] = clock(hd.duration)
  end
  if (hd.kills or 0) > 0 then bits[#bits + 1] = hd.kills .. (hd.kills == 1 and " kill" or " kills") end
  if (hd.deaths or 0) > 0 then bits[#bits + 1] = hd.deaths .. (hd.deaths == 1 and " death" or " deaths") end
  T.Text(x, y + th + 3 * s, table.concat(bits, DOT), hd.live and { 0.40, 0.88, 0.55, 1 } or C.muted, T.font.small)
  if hd.live then
    if T.Button("##dpsend", x + w - 100 * s, y + 4 * s, x + w, y + 28 * s, s, "End fight",
          { tooltip = "End this fight now (/dps end)" }) then
      P.command("end")
    end
  elseif hd.id == 0 then
    if T.Button("##dpsreset", x + w - 120 * s, y + 4 * s, x + w, y + 28 * s, s, "Reset per hour",
          { tooltip = "Count platinum and AA per hour from now (/dps reset)" }) then
      P.command("reset_rates")
    end
  else
    if T.Button("##dpsdel", x + w - 100 * s, y + 4 * s, x + w, y + 28 * s, s, "Delete", { tooltip = "Forget this fight" }) then
      P.command("delete", hd.id)
      sel.fight = nil
    end
  end

  -- the totals
  local ty = y + th + 26 * s
  local tw = (w - 3 * 10 * s) / 4
  local tiles = {
    { "DAMAGE", fmt(hd.total), nil, C.accent },
    { "GROUP DPS", fmt(hd.dps), nil, C.accent },
    { "YOUR DPS", fmt(hd.my_dps), hd.total > 0 and pct(hd.my_damage / hd.total * 100) .. " of it" or nil, C.gold },
    { "DAMAGE TAKEN", fmt(hd.taken), nil, C.hp },
  }
  for i, t in ipairs(tiles) do
    local x0 = x + (i - 1) * (tw + 10 * s)
    tile(x0, ty, x0 + tw, ty + 50 * s, s, t[1], t[2], t[3], t[4])
  end

  -- for the session: platinum and AA, per hour
  if hd.id == 0 and st.rates then
    local r = st.rates
    ty = ty + 60 * s
    local since = "since " .. r.since
    local more = {
      { "PLATINUM", plat(r.plat), (r.sales or 0) > 0 and (plat(r.looted) .. " loot" .. DOT .. plat(r.sold) .. " sold")
        or (r.loots .. (r.loots == 1 and " loot" or " loots")), C.platinum },
      { "PLATINUM / HOUR", r.plat_hour and plat(r.plat_hour) or "-", since, C.platinum },
      { "AA GAINED", aa(r.aa), clock(r.seconds), C.aa or C.gold },
      { "AA / HOUR", r.aa_hour and aa(r.aa_hour) or "-", since, C.aa or C.gold },
    }
    for i, t in ipairs(more) do
      local x0 = x + (i - 1) * (tw + 10 * s)
      tile(x0, ty, x0 + tw, ty + 50 * s, s, t[1], t[2], t[3], t[4])
    end
  end

  -- the graph
  local gy = ty + 60 * s
  local gh = math.max(110 * s, math.min(170 * s, h * 0.30))
  if hd.id == 0 then sessionGraph(cache.list, x, gy, x + w, gy + gh, s)
  else fightGraph(fd, x, gy, x + w, gy + gh, s) end

  -- the tables
  local tabY = gy + gh + 12 * s
  local tab = segmented("##dpstab", x + 2 * s, tabY, x + 340 * s, tabY + 22 * s, s, TABS, sel.tab)
  if tab then sel.tab = tab end
  local by = tabY + 32 * s
  local bh = y + h - by
  if sel.tab == "done" then
    local lw = w * 0.52
    local topV = fd.damage[1] and fd.damage[1].damage or 1
    table_("##dpsdone", x, by, lw, bh, s, fd.damage, {
      { "Name", 0, nil, nameCell },
      { "Damage", 70, "right", function(r) return fmt(r.damage), C.text end },
      { "%", 44, "right", function(r) return pct(r.pct) end },
      { "DPS", 62, "right", function(r) return fmt(r.dps), C.text end },
    }, {
      selected = function(r) return r.name == sel.actor end,
      onClick = function(r) sel.actor = r.name end,
      bar = function(r) return r.damage / topV, classColor(r.class) end,
      tip = function(r)
        return string.format("%s\n%s damage, %s dps (%s while hitting)\n%d hits, %d misses, %d crits\nBiggest: %s%s",
          r.name, T.Thousands(r.damage), fmt(r.dps), fmt(r.active_dps), r.hits, r.misses, r.crits,
          T.Thousands(r.max), r.max_ability and (" (" .. r.max_ability .. ")") or "")
      end,
      empty = "No damage done",
    })
    abilityPanel(x + lw + 10 * s, by, w - lw - 10 * s, bh, s, fd)
  elseif sel.tab == "taken" then
    local lw = w * 0.5
    local topT = fd.taken[1] and fd.taken[1].taken or 1
    table_("##dpstaken", x, by, lw, bh, s, fd.taken, {
      { "Name", 0, nil, nameCell },
      { "Taken", 74, "right", function(r) return fmt(r.taken), C.text end },
      { "%", 48, "right", function(r) return pct(r.pct) end },
    }, { bar = function(r) return r.taken / topT, C.hp end, empty = "Nobody was hit" })
    local by_dealt = {}
    for _, m in ipairs(fd.mobs) do if (m.dealt or 0) > 0 then by_dealt[#by_dealt + 1] = m end end
    table.sort(by_dealt, function(a, b) return a.dealt > b.dealt end)
    local topD = by_dealt[1] and by_dealt[1].dealt or 1
    table_("##dpsdealt", x + lw + 10 * s, by, w - lw - 10 * s, bh, s, by_dealt, {
      { "Hit by", 0, nil, function(r) return r.name, C.text end },
      { "Damage", 74, "right", function(r) return fmt(r.dealt), C.text end },
      { "%", 48, "right", function(r) return pct(hd.taken > 0 and r.dealt / hd.taken * 100 or 0) end },
    }, { bar = function(r) return r.dealt / topD, C.danger end, empty = "No mob hit you" })
  else
    local topM = fd.mobs[1] and fd.mobs[1].taken or 1
    table_("##dpsmobs", x, by, w, bh, s, fd.mobs, {
      { "Mob", 0, nil, function(r) return r.name, C.text end },
      { "Damage taken", 100, "right", function(r) return fmt(r.taken), C.text end },
      { "%", 50, "right", function(r) return pct(hd.total > 0 and r.taken / hd.total * 100 or 0) end },
      { "Dealt", 80, "right", function(r) return fmt(r.dealt) end },
      { hd.id == 0 and "Kills" or "Status", 150, "right", function(r)
        if hd.id == 0 then return tostring(r.kills or 0), (r.kills or 0) > 0 and C.text or C.faint end
        if r.killed then return r.killer and ("Slain by " .. r.killer) or "Slain", { 0.40, 0.88, 0.55, 1 } end
        return "Alive", C.faint
      end },
    }, { bar = function(r) return r.taken / topM, C.accent end, empty = "No mobs" })
  end
end

local function optionsPage(x, y, w, h, s)
  local S = st.settings or {}
  local _, th = T.TextSize("Ag", T.font.large)
  T.Text(x, y, "Options", C.text, T.font.large)
  T.Text(x, y + th + 3 * s, "How fights are cut, who counts, and what is kept.", C.muted, T.font.small)
  local yy = y + th + 34 * s
  local labelW = 240 * s
  local function row(text, hint)
    T.Text(x, yy + 3 * s, text, C.text, T.font.normal)
    if hint then T.Text(x, yy + 21 * s, hint, C.faint, T.font.tiny) end
    ui.SetCursorScreenPos(x + labelW, yy)
  end
  row("Who counts", "Your group and its pets, or every player near you")
  local who = segmented("##dpswho", x + labelW, yy + 2 * s, x + labelW + 220 * s, yy + 24 * s, s,
    { { "group", "Group" }, { "everyone", "Everyone" } }, S.who)
  if who then P.set("who", who) end
  yy = yy + 46 * s
  row("Pets", "A pet's damage counts for its owner")
  local v, changed = ui.Checkbox("Merge pets into their owners##dpspets", S.merge_pets == true)
  if changed then P.set("merge_pets", v) end
  yy = yy + 46 * s
  row("A fight ends after", "Seconds with no hit; sooner after a kill")
  ui.SetNextItemWidth(220 * s)
  local n
  n, changed = ui.SliderInt("##dpsidle", S.idle or 6, 2, 60, (S.idle or 6) .. " seconds")
  if changed then P.set("idle", n) end
  yy = yy + 46 * s
  row("Most bars in the meter", "It grows to fit each player, up to this many, and shrinks back")
  ui.SetNextItemWidth(220 * s)
  n, changed = ui.SliderInt("##dpsrows", S.rows or 6, 3, 12, (S.rows or 6) .. " players")
  if changed then P.set("rows", n) end
  yy = yy + 46 * s
  row("Per hour", "Platinum looted and AA gained, under the meter's bars")
  v, changed = ui.Checkbox("Show platinum and AA per hour##dpsrates", S.show_rates ~= false)
  if changed then P.set("show_rates", v) end
  yy = yy + 46 * s
  row("Fights kept", "The oldest go first; they are kept between logins")
  ui.SetNextItemWidth(220 * s)
  n, changed = ui.SliderInt("##dpshist", S.history or 40, 5, 200, (S.history or 40) .. " fights")
  if changed then P.set("history", n) end
  yy = yy + 56 * s
  ui.DrawLine(x, yy, x + w, yy, C.ink[1], C.ink[2], C.ink[3], 0.08, 1)
  yy = yy + 12 * s
  ui.SetCursorScreenPos(x, yy)
  ui.PushTextWrapPos(x + w - ui.GetWindowPos())
  ui.TextColored(C.faint[1], C.faint[2], C.faint[3], 1,
    "Damage is read from the combat lines in chat. What your chat filters hide is not counted, and the hit display"
    .. " options must show full sentences (the default). Damage over time and damage shields count for the caster;"
    .. " a pet's spells are not in chat, so only its melee counts.")
  ui.PopTextWrapPos()
  if T.Button("##dpsclear", x, y + h - 28 * s, x + 150 * s, y + h, s, "Clear all fights",
        { tooltip = "Forget every fight kept (/dps clear)" }) then
    P.command("clear")
    sel.fight = nil
  end
end

-- ---------------------------------------------------------------- the details: the list down the left

local function card(f, x0, y0, x1, y1, s, on)
  local hit = T.Hit("##dpsfight" .. f.id, x0, y0, x1, y1)
  local hovered = ui.IsItemHovered()
  local a = C.accent
  if on then
    ui.DrawRectFilled(x0, y0, x1, y1, a[1], a[2], a[3], 0.16, 6 * s)
    ui.DrawRectFilled(x0, y0 + 8 * s, x0 + 3 * s, y1 - 8 * s, a[1], a[2], a[3], 1, 2 * s)
  elseif hovered then
    ui.DrawRectFilled(x0, y0, x1, y1, C.ink[1], C.ink[2], C.ink[3], 0.06, 6 * s)
  end
  local px = x0 + 12 * s
  local right = f.id == 0 and ((f.count or 0) .. " fights") or clock(f.duration)
  local rw = T.TextSize(right, T.font.tiny)
  local name = f.name .. ((f.extra or 0) > 0 and (" +" .. f.extra) or "")
  T.Text(px, y0 + 7 * s, T.Fit(name, x1 - px - rw - 14 * s, T.font.normal), on and C.text or C.text, T.font.normal)
  T.Text(x1 - 8 * s, y0 + 9 * s, right, C.faint, T.font.tiny, "right")
  T.Text(px, y0 + 26 * s, fmt(f.total) .. DOT .. fmt(f.dps) .. " dps", C.muted, T.font.small)
  if f.live then
    local p = 0.6 + 0.4 * math.sin(ui.GetTime() * 4)
    T.Text(x1 - 8 * s, y0 + 27 * s, "LIVE", { 0.40, 0.88, 0.55, 1 }, T.font.tiny, "right", p)
  elseif f.id ~= 0 then
    T.Text(x1 - 8 * s, y0 + 27 * s, f.ago, C.faint, T.font.tiny, "right")
  end
  if hovered and f.id ~= 0 then
    ui.SetTooltip(string.format("%s%s\n%s%s%s%s%s damage, %s dps", f.name, (f.extra or 0) > 0 and (" and " .. f.extra
      .. " more") or "", f.zone ~= "" and (f.zone .. DOT) or "", f.when, DOT, clock(f.duration) .. DOT, fmt(f.total),
      fmt(f.dps)))
  end
  return hit
end

local function sidebar(x, y, w, h, s)
  ui.DrawRectFilled(x, y, x + w, y + h, C.inset[1], C.inset[2], C.inset[3], C.inset[4] * 0.6, 8 * s)
  T.Text(x + 12 * s, y + 9 * s, "FIGHTS", C.faint, T.font.tiny)
  local count = 0
  for _, f in ipairs(cache.list) do if f.id ~= 0 then count = count + 1 end end
  T.Text(x + w - 12 * s, y + 9 * s, tostring(count), C.faint, T.font.tiny, "right")
  local cardH = 46 * s
  local yy = y + 26 * s
  -- the session, then the fights in a list that scrolls
  local session = { id = 0, name = "Session", extra = 0, total = 0, dps = 0, duration = 0, count = count }
  local dur = 0
  for _, f in ipairs(cache.list) do
    session.total = session.total + f.total
    dur = dur + f.duration
  end
  session.duration = dur
  session.dps = dur > 0 and session.total / dur or 0
  if card(session, x + 6 * s, yy, x + w - 6 * s, yy + cardH, s, sel.page == "fight" and sel.fight == 0) then
    sel.fight, sel.page = 0, "fight"
  end
  yy = yy + cardH + 6 * s
  ui.DrawLine(x + 12 * s, yy - 3 * s, x + w - 12 * s, yy - 3 * s, C.ink[1], C.ink[2], C.ink[3], 0.08, 1)
  local footH = 38 * s
  ui.SetCursorScreenPos(x, yy)
  ui.BeginChild("##dpsfights", w, y + h - footH - yy, false, ui.WindowFlags.NoBackground)
  local top = select(2, ui.GetCursorScreenPos())
  for i, f in ipairs(cache.list) do
    if f.id ~= 0 then
      local cy = top + (i - 1) * (cardH + 4 * s)
      if card(f, x + 6 * s, cy, x + w - 6 * s, cy + cardH, s, sel.page == "fight" and sel.fight == f.id) then
        sel.fight, sel.page = f.id, "fight"
      end
    end
  end
  ui.SetCursorScreenPos(x, top + #cache.list * (cardH + 4 * s))
  ui.Dummy(1, 2 * s)
  ui.EndChild()
  if #cache.list == 0 then
    T.Text(x + w / 2, yy + 20 * s, "None yet", C.faint, T.font.small, "center")
  end
  -- the foot: options
  local fy = y + h - footH + 6 * s
  ui.DrawLine(x + 12 * s, fy - 4 * s, x + w - 12 * s, fy - 4 * s, C.ink[1], C.ink[2], C.ink[3], 0.08, 1)
  if iconButton("##dpsopts", x + 8 * s, fy + 2 * s, 24 * s, s, sel.page == "options", "Options", gearIcon) then
    sel.page = sel.page == "options" and "fight" or "options"
  end
  T.Text(x + 38 * s, fy + 7 * s, (st.settings and st.settings.who == "everyone") and "Counting everyone"
    or "Counting your group", C.faint, T.font.small)
end

-- What the details show, read again when a fight changes (at most four times a second) or the choice changes.
local function refresh()
  local now = ui.GetTime()
  local changed = st.list_rev ~= cache.rev
  if changed and now - cache.at < 0.25 and cache.fight then changed = false end
  if changed then
    cache.list = P.list() or {}
    cache.rev, cache.at = st.list_rev, now
  end
  -- the choice: kept while it exists, else the newest fight
  local found = sel.fight == 0
  for _, f in ipairs(cache.list) do if f.id == sel.fight then found = true end end
  if not found then sel.fight = cache.list[1] and cache.list[1].id or 0 end
  local key = tostring(sel.fight)
  if changed or cache.fightKey ~= key then
    cache.fight = (#cache.list > 0) and P.fight(sel.fight) or nil
    cache.fightKey = key
    cache.abKey = nil
  end
  local fd = cache.fight
  if fd then
    local present = false
    for _, r in ipairs(fd.damage) do if r.name == sel.actor then present = true end end
    if not present then
      sel.actor = nil
      for _, r in ipairs(fd.damage) do if r.name == st.me then sel.actor = r.name end end
      if not sel.actor and fd.damage[1] then sel.actor = fd.damage[1].name end
    end
    local abKey = key .. "/" .. tostring(sel.actor) .. "/" .. tostring(cache.rev)
    if cache.abKey ~= abKey then
      cache.abilities = sel.actor and P.abilities(sel.fight, sel.actor) or {}
      cache.abKey = abKey
    end
  end
end

local function details(x, y, w, h, s)
  scale = s
  refresh()
  local sideW = 230 * s
  sidebar(x, y, sideW, h, s)
  local cx = x + sideW + 16 * s
  local cw = w - sideW - 16 * s
  if sel.page == "options" then optionsPage(cx, y, cw, h, s) else fightPage(cx, y, cw, h, s) end
end

ui.window("DPS Meter", function()
  P = eq.Plugin("dpsmeter")
  if not P or not eq.InGame() then return end
  st = P.state() or {}
  if not st.open and not st.details_open then return end
  hud.Window(nil, "DPS Meter", {
    shown = function() return st.open end,
    size = compactSize,
    place = function(W, H, w, h) return W - w - 40, H * 0.55 end,
    onClose = function() P.command("close") end,
  }, meter)
  hud.Dialog(DETAILS_KEY, "DPS Meter", {
    shown = st.details_open == true,
    keepTitle = true,
    size = function() return 1000, 680 end,
    resizable = { 860, 560 },
    place = function(W, H, w, h) return (W - w) / 2, (H - h) / 2 end,
    onClose = function() P.command("close_details") end,
  }, details)
end)
