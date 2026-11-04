-- Fights from combat events (lib/parse.lua). Pure: the caller says who each name is (ctx.classify) and what time it
-- is, so this is tested with plain Lua.
--
-- A fight starts with the first hit between our side (the player, the group, their pets; every player with
-- "everyone") and an NPC, and ends once nothing has hit for `idle_ms` (sooner after a kill). It keeps, per actor of
-- our side: damage done (by ability), hits, misses, crits, the biggest hit, damage taken, and damage per second of
-- the fight; per NPC: damage taken and dealt, and whether it died; and the whole side's damage, second by second.
local parse = require('lib.parse')

local fights = {}

fights.TIMELINE_MAX = 900 -- seconds a fight's graph keeps (15 minutes); longer fights keep their totals

function fights.new(opts)
  opts = opts or {}
  return {
    idle_ms = opts.idle_ms or 6000,
    after_kill_ms = opts.after_kill_ms or 2500,
    max_history = opts.max_history or 40,
    merge_pets = opts.merge_pets ~= false,
    current = nil,
    history = {},   -- finished fights, newest first
    next_id = 1,
    rev = 1,        -- bumped on every change the windows should see
  }
end

local function actor(f, name, class)
  local a = f.actors[name]
  if not a then
    a = { name = name, damage = 0, hits = 0, misses = 0, crits = 0, max = 0, taken = 0, pet = 0, first = nil,
      last = nil, abilities = {}, timeline = {} }
    f.actors[name] = a
  end
  if class and class ~= 0 then a.class = class end
  return a
end

local function mob(f, name)
  local m = f.mobs[name]
  if not m then
    m = { name = name, taken = 0, dealt = 0, killed = false }
    f.mobs[name] = m
  end
  return m
end

local function bucket(list, i, amount)
  for k = #list + 1, i - 1 do list[k] = 0 end
  list[i] = (list[i] or 0) + amount
end

local function second(f, now)
  return math.floor((now - f.start) / 1000) + 1
end

local function start(F, now, ctx)
  local f = {
    id = F.next_id, start = now, last = now, wall = ctx.wall, zone = ctx.zone, me = ctx.me,
    total = 0, taken = 0, kills = 0, deaths = {}, actors = {}, mobs = {}, timeline = {},
  }
  F.next_id = F.next_id + 1
  F.current = f
  return f
end

-- Seconds the fight lasted (at least one, so a one-hit fight has a rate).
function fights.duration(f)
  return math.max(1, (f.last - f.start) / 1000)
end

-- The mob the fight is named after (the one that took the most damage) and how many others there were.
function fights.title(f)
  local best, n = nil, 0
  for _, m in pairs(f.mobs) do
    n = n + 1
    if not best or m.taken > best.taken or (m.taken == best.taken and m.name < best.name) then best = m end
  end
  if not best then return "Fight", 0 end
  return best.name, n - 1
end

local function ours(info) return info and (info.side == "me" or info.side == "friend") end
local function enemy(info) return info and info.side == "enemy" end

-- Who an action of `name` is credited to: the owner for a pet (when pets are merged).
local function credit(F, name, info)
  if info.owner and F.merge_pets then return info.owner, true end
  return name, false
end

-- Feeds one event. ctx = { me = the player's name, classify = function(name) -> { side = "me" | "friend" |
-- "enemy" | "other", name = <the name as kept, when it differs: "A gnoll" at a sentence's start is "a gnoll">,
-- owner = <owner's name for a pet>, class = <class id> }, wall = os.time(), zone = <zone> }.
-- Returns true when the event counted.
function fights.event(F, ev, now, ctx)
  if not ev then return false end
  local function name(n) if n == parse.ME then return ctx.me end return n end
  local src, dst = name(ev.src), name(ev.dst)
  local f = F.current

  if ev.kind == "death" then
    if not f then return false end
    local victim, killer = name(ev.victim), name(ev.killer)
    local vi = ctx.classify(victim)
    victim = vi.name or victim
    if enemy(vi) or f.mobs[victim] then
      local m = mob(f, victim)
      if not m.killed then
        m.killed = true
        f.kills = f.kills + 1
      end
      m.killer = killer
      f.kill_at = now
    elseif ours(vi) then
      f.deaths[#f.deaths + 1] = victim
    else
      return false
    end
    F.rev = F.rev + 1
    return true
  end

  if ev.kind == "crit" then
    if not f then return false end
    local si = ctx.classify(src)
    if not ours(si) then return false end
    src = si.name or src
    local who, is_pet = credit(F, src, si)
    local a = actor(f, who, (not is_pet) and si.class or nil)
    a.crits = a.crits + 1
    return true
  end

  local si, di = ctx.classify(src), ctx.classify(dst)
  src, dst = si.name or src, di.name or dst
  local outgoing = ours(si) and enemy(di)
  local incoming = enemy(si) and ours(di)
  if not outgoing and not incoming then return false end

  if ev.kind == "miss" then
    if not f then return false end -- a miss alone does not start a fight
    if outgoing then
      local who = credit(F, src, si)
      local a = actor(f, who, si.class)
      a.misses = a.misses + 1
    end
    return true
  end

  local amount = tonumber(ev.amount) or 0
  if amount <= 0 then return false end
  f = f or start(F, now, ctx)
  f.last = now
  f.kill_at = nil
  local sec = second(f, now)

  if outgoing then
    local who, is_pet = credit(F, src, si)
    local a = actor(f, who, (not is_pet) and si.class or nil)
    a.damage = a.damage + amount
    a.hits = a.hits + 1
    if amount > a.max then a.max = amount a.max_ability = ev.ability end
    a.first = a.first or now
    a.last = now
    if is_pet then a.pet = a.pet + amount end
    local key = ev.ability or "?"
    if ev.kind == "melee" then key = key:sub(1, 1):upper() .. key:sub(2) end
    if is_pet then key = "Pet: " .. key end
    local ab = a.abilities[key]
    if not ab then
      ab = { name = key, kind = ev.kind, damage = 0, hits = 0, max = 0 }
      a.abilities[key] = ab
    end
    ab.damage = ab.damage + amount
    ab.hits = ab.hits + 1
    if amount > ab.max then ab.max = amount end
    if sec <= fights.TIMELINE_MAX then
      bucket(a.timeline, sec, amount)
      bucket(f.timeline, sec, amount)
    end
    f.total = f.total + amount
    mob(f, dst).taken = mob(f, dst).taken + amount
  else
    local who = credit(F, dst, di)
    local a = actor(f, who, di.owner and nil or di.class)
    a.taken = a.taken + amount
    f.taken = f.taken + amount
    mob(f, src).dealt = mob(f, src).dealt + amount
  end
  F.rev = F.rev + 1
  return true
end

-- Ends the current fight once it has been quiet long enough. Returns the finished fight, if one ended.
function fights.tick(F, now)
  local f = F.current
  if not f then return nil end
  local quiet = now - f.last
  if quiet < F.idle_ms and not (f.kill_at and now - f.kill_at >= F.after_kill_ms) then return nil end
  return fights.finish(F)
end

-- Ends the current fight now (a fight with no damage done by our side is dropped).
function fights.finish(F)
  local f = F.current
  if not f then return nil end
  F.current = nil
  F.rev = F.rev + 1
  if f.total <= 0 then return nil end
  f.name, f.extra = fights.title(f)
  f.duration = fights.duration(f)
  f.kill_at = nil
  table.insert(F.history, 1, f)
  while #F.history > F.max_history do table.remove(F.history) end
  return f
end

-- The actors by damage done (or by damage taken), each with its share and rates.
function fights.ranked(f, by)
  by = by or "damage"
  local dur = f.duration or fights.duration(f)
  local list = {}
  local total = by == "taken" and f.taken or f.total
  for _, a in pairs(f.actors) do
    if (a[by] or 0) > 0 then
      local active = a.first and math.max(1, (a.last - a.first) / 1000) or dur
      list[#list + 1] = {
        name = a.name, class = a.class, value = a[by], damage = a.damage, taken = a.taken,
        pct = total > 0 and a[by] / total * 100 or 0,
        dps = a.damage / dur, active_dps = a.damage / active,
        hits = a.hits, misses = a.misses, crits = a.crits, max = a.max, max_ability = a.max_ability, pet = a.pet,
        accuracy = (a.hits + a.misses) > 0 and a.hits / (a.hits + a.misses) * 100 or nil,
      }
    end
  end
  table.sort(list, function(x, y)
    if x.value ~= y.value then return x.value > y.value end
    return x.name < y.name
  end)
  return list
end

-- An actor's abilities by damage, each with its share.
function fights.abilities(f, name)
  local a = f.actors[name]
  if not a then return {} end
  local list = {}
  for _, ab in pairs(a.abilities) do
    list[#list + 1] = { name = ab.name, kind = ab.kind, damage = ab.damage, hits = ab.hits, max = ab.max,
      avg = ab.hits > 0 and ab.damage / ab.hits or 0, pct = a.damage > 0 and ab.damage / a.damage * 100 or 0 }
  end
  table.sort(list, function(x, y)
    if x.damage ~= y.damage then return x.damage > y.damage end
    return x.name < y.name
  end)
  return list
end

-- The mobs by damage they took.
function fights.mobs(f)
  local list = {}
  for _, m in pairs(f.mobs) do list[#list + 1] = m end
  table.sort(list, function(x, y)
    if x.taken ~= y.taken then return x.taken > y.taken end
    return x.name < y.name
  end)
  return list
end

-- Every finished fight (and the current one) as one: damage and time added up, for "Session".
function fights.session(F)
  local s = { id = 0, name = "Session", extra = 0, total = 0, taken = 0, kills = 0, deaths = {}, actors = {},
    mobs = {}, timeline = {}, duration = 0, count = 0 }
  local list = {}
  if F.current and F.current.total > 0 then list[1] = F.current end
  for _, f in ipairs(F.history) do list[#list + 1] = f end
  for _, f in ipairs(list) do
    s.count = s.count + 1
    s.total = s.total + f.total
    s.taken = s.taken + f.taken
    s.kills = s.kills + f.kills
    s.duration = s.duration + (f.duration or fights.duration(f))
    for name, a in pairs(f.actors) do
      local b = actor(s, name, a.class)
      b.damage, b.hits, b.misses = b.damage + a.damage, b.hits + a.hits, b.misses + a.misses
      b.crits, b.taken, b.pet = b.crits + a.crits, b.taken + a.taken, b.pet + a.pet
      if a.max > b.max then b.max, b.max_ability = a.max, a.max_ability end
      for key, ab in pairs(a.abilities) do
        local c = b.abilities[key]
        if not c then
          c = { name = ab.name, kind = ab.kind, damage = 0, hits = 0, max = 0 }
          b.abilities[key] = c
        end
        c.damage, c.hits = c.damage + ab.damage, c.hits + ab.hits
        if ab.max > c.max then c.max = ab.max end
      end
    end
    for name, m in pairs(f.mobs) do
      local n = mob(s, name)
      n.taken, n.dealt = n.taken + m.taken, n.dealt + m.dealt
      if m.killed then n.kills = (n.kills or 0) + 1 end
    end
  end
  s.duration = math.max(1, s.duration)
  -- (no first/last per actor across fights: active rates are the session's)
  return s
end

-- Settings that change how fights are cut and kept.
function fights.configure(F, opts)
  if opts.idle_ms then F.idle_ms = opts.idle_ms end
  if opts.max_history then
    F.max_history = opts.max_history
    while #F.history > F.max_history do table.remove(F.history) end
  end
  if opts.merge_pets ~= nil then F.merge_pets = opts.merge_pets end
  F.rev = F.rev + 1
end

function fights.clear(F)
  F.history = {}
  F.current = nil
  F.rev = F.rev + 1
end

function fights.remove(F, id)
  for i, f in ipairs(F.history) do
    if f.id == id then
      table.remove(F.history, i)
      F.rev = F.rev + 1
      return true
    end
  end
  return false
end

function fights.find(F, id)
  if F.current and F.current.id == id then return F.current end
  for _, f in ipairs(F.history) do if f.id == id then return f end end
  return nil
end

-- Kept history read back: ids renumbered after the highest, anything malformed dropped.
function fights.restore(F, saved)
  if type(saved) ~= "table" then return end
  local out = {}
  for _, f in ipairs(saved) do
    if type(f) == "table" and type(f.actors) == "table" and type(f.mobs) == "table" and tonumber(f.total) then
      f.timeline = type(f.timeline) == "table" and f.timeline or {}
      f.deaths = type(f.deaths) == "table" and f.deaths or {}
      f.duration = tonumber(f.duration) or fights.duration(f)
      out[#out + 1] = f
      if (tonumber(f.id) or 0) >= F.next_id then F.next_id = math.floor(f.id) + 1 end
    end
  end
  while #out > F.max_history do table.remove(out) end
  F.history = out
  F.rev = F.rev + 1
end

return fights
