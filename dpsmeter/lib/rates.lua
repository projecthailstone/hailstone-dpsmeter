-- Platinum and AA per hour, since the script started (or the last reset). Pure: the caller gives it the lines and
-- samples and the time, so it is tested with plain Lua.
--
-- Coin: the client's loot lines, eqstr 12072 "You receive %1 from the corpse." and 12071 "You receive %1 as your
-- split." (a group member's autosplit, or your own), %1 as the client writes it ("3 platinum, 2 gold and 5 copper").
-- On a server with NMSloot, what it sells for you counts too: "[NMS] <item> sold for 2 platinum, 3 gold." (kept
-- apart as `sold`, so the windows can show both). Coin from merchants, trades or the bank is not loot, so the purse
-- itself is not watched.
-- AA: unspent points plus the progress toward the next one (Me.AAPoints, Me.PctAAExp), sampled. A point spent takes
-- one off the unspent count without being a loss, so a drop in points is not counted against the rate.
local rates = {}

local COIN = { platinum = 1000, gold = 100, silver = 10, copper = 1 }

function rates.new(now, wall)
  return { start = now, wall = wall, copper = 0, loots = 0, sold = 0, sales = 0, aa = 0, last_points = nil,
    last_pct = nil }
end

function rates.reset(r, now, wall)
  r.start, r.wall, r.copper, r.loots, r.sold, r.sales, r.aa = now, wall, 0, 0, 0, 0, 0
  -- (the last sample stays: the next one counts from it)
end

-- The copper in a coin text: "3 platinum, 2 gold and 5 copper" -> 3205.
function rates.copper_of(text)
  local total = 0
  for n, kind in tostring(text or ""):gmatch("(%d+) (%a+)") do
    local each = COIN[kind]
    if each then total = total + tonumber(n) * each end
  end
  return total
end

-- A chat line; true when it was loot or a sale.
function rates.line(r, text)
  if type(text) ~= "string" then return false end
  text = text:gsub("^%[%d+:%d+:%d+%] ", "") -- (a chat timestamp, if the line carries one)
  local price = text:match("^%[NMS%] .+ sold for (.+)%.$")
  if price then
    local c = rates.copper_of(price)
    if c <= 0 then return false end
    r.sold = r.sold + c
    r.sales = r.sales + 1
    return true
  end
  local coins = text:match("^You receive (.+) from the corpse%.$") or text:match("^You receive (.+) as your split%.$")
  if not coins then return false end
  local c = rates.copper_of(coins)
  if c <= 0 then return false end
  r.copper = r.copper + c
  r.loots = r.loots + 1
  return true
end

-- A sample of the AA counters: points unspent and the percent toward the next (nil when not known yet).
function rates.aa_sample(r, points, pct)
  points, pct = tonumber(points), tonumber(pct)
  if not points or not pct then return end
  local lp, lpct = r.last_points, r.last_pct
  r.last_points, r.last_pct = points, pct
  if not lp then return end
  local gained
  if points > lp then
    gained = (points - lp) + (pct - lpct) / 100
  elseif points == lp then
    gained = (pct - lpct) / 100
  else
    gained = math.max(0, (pct - lpct) / 100) -- points spent
  end
  r.aa = r.aa + gained
end

-- What the windows show. Rates need a minute behind them first (nil until then).
function rates.summary(r, now)
  local secs = math.max(0, (now - r.start) / 1000)
  local hours = secs / 3600
  local ready = secs >= 60
  local total = (r.copper + r.sold) / 1000
  return {
    seconds = secs, wall = r.wall, plat = total, looted = r.copper / 1000, loots = r.loots, sold = r.sold / 1000,
    sales = r.sales, aa = r.aa,
    plat_hour = ready and total / hours or nil,
    aa_hour = ready and r.aa / hours or nil,
  }
end

return rates
