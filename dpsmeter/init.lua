-- DPS Meter for Hailstone: reads the combat lines in chat and keeps fights, for two windows.
--   The meter (opens with the script; /dps, or the EQ menu's Plugins > DPS Meter): the fight now (or the last one),
--           or the whole session, as a bar per player with their damage and damage per second, and a graph.
--   The details (its list button, or /dps details): every fight kept, newest first; for the chosen one a graph of
--           damage per second, each player's damage, rate, hits, accuracy, crits and biggest hit, their abilities,
--           the damage each took, and the mobs.
--   Both show platinum (looted, and sold for you by NMSloot) and AA gained per hour since the script started (lib/rates.lua; /dps reset starts
--           them again).
--
-- Who counts: you, your group and their pets (or every player, Options > Everyone), hitting an NPC or hit by one.
-- A fight starts at the first such hit and ends when nothing has hit for a while (Options), sooner after a kill.
-- Damage is read from chat (lib/parse.lua), so what your chat filters hide is not counted, and the hit display
-- modes must show full sentences (the default).
--
-- /dps [show | details | end | clear | reset | everyone | group]
-- Settings and the fights are kept per server and character in scripts/config/dpsmeter/.
local mq = require('mq')
local hs = require('hailstone')
local parse = require('lib.parse')
local fights = require('lib.fights')
local rates = require('lib.rates')

local TICK_MS = 50
local SPAWNS_MS = 1000

local DEFAULTS = { idle = 6, who = "group", merge_pets = true, history = 40, rows = 6, view = "fight", show_rates = true }
local S = {}
for k, v in pairs(DEFAULTS) do S[k] = v end

local F = fights.new({ idle_ms = S.idle * 1000, max_history = S.history })
local R = rates.new(mq.gettime(), os.time()) -- platinum and AA per hour
local AA_MS = 1000
local aa_at = -1e9
local open = true
local details_open = false
local paths = nil         -- this character's settings and fights files
local settings_dirty, history_dirty = nil, nil
local rev = 1             -- bumped when a setting changes (the window reads the settings again)

local function say(text) hs.chat('[DPS Meter] ' .. text, 15) end

-- ---------------------------------------------------------------- who is who

local me = ""
local zone = 0
local by_name = {}   -- lower-case shown name -> { name, npc, owner (id), class, id }
local by_id = {}     -- spawn id -> the same
local group = {}     -- lower-case name -> true
local spawns_at = -1e9

local function read_spawns(now)
  spawns_at = now
  local p = hs.player()
  me = p and p.name or me
  local all = hs.spawns() or {}
  local names, ids = {}, {}
  for _, s in pairs(all) do
    if not s.corpse then
      local shown = parse.display_name(s.name)
      local e = { name = shown, npc = s.npc, owner = s.owner or 0, class = s.class, id = s.id, merc = s.mercenary }
      ids[s.id] = e
      -- a live spawn wins over a corpse of the same name, and over one already seen
      names[shown:lower()] = e
    end
  end
  -- names that went (a mob killed and rotted, a pet dismissed) are remembered for the zone: their lines still come
  for k, e in pairs(by_name) do if not names[k] then names[k] = e end end
  by_name, by_id = names, ids
  group = {}
  local n = tonumber(mq.TLO.Group.Members()) or 0
  for i = 1, n do
    local name = mq.TLO.Group.Member(i).Name()
    if name and name ~= "" then group[parse.display_name(name):lower()] = true end
  end
end

local function player_side(name)
  if name:lower() == me:lower() then return "me" end
  if group[name:lower()] or S.who == "everyone" then return "friend" end
  return "other"
end

-- The kinds fights.event needs: me, friend (group, or any player with "everyone", and their pets), enemy (an NPC
-- that is no player's pet), or other.
local classify
classify = function(name, depth)
  if not name or name == "" then return { side = "other" } end
  if name:lower() == me:lower() then return { side = "me", name = me, class = by_name[me:lower()] and by_name[me:lower()].class } end
  local e = by_name[name:lower()]
  if not e and mq.gettime() - spawns_at > 250 then
    read_spawns(mq.gettime()) -- a spawn that came since the last read
    e = by_name[name:lower()]
  end
  if e then
    if not e.npc and not e.merc then
      return { side = player_side(e.name), name = e.name, class = e.class }
    end
    if e.merc then -- (a mercenary counts on its own, as a group member does)
      return { side = (S.who == "everyone" or group[e.name:lower()]) and "friend" or "other", name = e.name }
    end
    if e.owner ~= 0 then
      local o = by_id[e.owner]
      if o and not o.npc then
        local side = player_side(o.name)
        if side == "other" then return { side = "other", name = e.name } end
        return { side = "friend", name = e.name, owner = o.name }
      end
      return { side = "enemy", name = e.name }
    end
    return { side = "enemy", name = e.name }
  end
  -- A swarm pet comes with no owner (stock EQEmu): it is named for its owner, "Soandso`s warder" or "Soandso's Pet".
  local owner = name:match("^(.-)[`']s ")
  if owner and owner ~= "" and (depth or 0) == 0 then
    local o = classify(owner, 1)
    if o.side == "me" or o.side == "friend" then return { side = "friend", name = name, owner = o.name } end
  end
  return { side = "other" }
end

local ctx = { classify = function(n) return classify(n) end }

-- ---------------------------------------------------------------- settings and the fights kept

local function clean(s) return (tostring(s or ""):gsub("[^%w_%-]", "_")) end

local function apply()
  fights.configure(F, { idle_ms = S.idle * 1000, max_history = S.history, merge_pets = S.merge_pets })
end

local function load_all()
  local server = mq.TLO.EverQuest.Server() or ""
  local char = mq.TLO.Me.Name() or ""
  if server == "" or char == "" then return end
  local base = "dpsmeter/" .. clean(server) .. "_" .. clean(char)
  if paths and paths.base == base then return end
  if paths then R = rates.new(mq.gettime(), os.time()) end -- another character: its own rates
  paths = { base = base, settings = base .. ".lua", fights = base .. "_fights.lua" }
  local chunk = loadfile(paths.settings)
  local ok, t = false, nil
  if chunk then ok, t = pcall(chunk) end
  S = {}
  for k, v in pairs(DEFAULTS) do S[k] = v end
  if ok and type(t) == "table" then
    for k, v in pairs(DEFAULTS) do
      if type(t[k]) == type(v) then S[k] = t[k] end
    end
  end
  apply()
  chunk = loadfile(paths.fights)
  ok, t = false, nil
  if chunk then ok, t = pcall(chunk) end
  if ok then fights.restore(F, t) end
  rev = rev + 1
end

local function save_due(now)
  if not paths then return end
  if settings_dirty and now - settings_dirty > 1500 then
    mq.pickle(paths.settings, S)
    settings_dirty = nil
  end
  if history_dirty and now - history_dirty > 3000 then
    mq.pickle(paths.fights, F.history)
    history_dirty = nil
  end
end

local LIMITS = { idle = { 2, 60 }, history = { 5, 200 }, rows = { 3, 12 } }

local function set(key, value)
  local d = DEFAULTS[key]
  if d == nil or type(value) ~= type(d) then return false end
  if key == "who" and value ~= "group" and value ~= "everyone" then return false end
  if key == "view" and value ~= "fight" and value ~= "session" then return false end
  if LIMITS[key] then value = math.max(LIMITS[key][1], math.min(LIMITS[key][2], math.floor(value))) end
  S[key] = value
  apply()
  settings_dirty = mq.gettime()
  if key == "history" then history_dirty = mq.gettime() end
  rev = rev + 1
  return true
end

-- ---------------------------------------------------------------- what the windows see

local function reset_rates()
  rates.reset(R, mq.gettime(), os.time())
end

-- The rates for the windows: since when, and the per-hour numbers (nil in the first minute).
local function rates_view()
  local r = rates.summary(R, mq.gettime())
  r.since = os.date("%H:%M", r.wall)
  return r
end

local function ago(wall)
  if not wall then return "" end
  local d = os.time() - wall
  if d < 60 then return "just now" end
  if d < 3600 then return math.floor(d / 60) .. "m ago" end
  if d < 86400 then return math.floor(d / 3600) .. "h ago" end
  return math.floor(d / 86400) .. "d ago"
end

local function title(f)
  if f.id == 0 then return "Session", 0 end
  if f.name then return f.name, f.extra or 0 end
  return fights.title(f)
end

-- A fight's head: its name, length, totals, and the player's own share.
local function head(f, live)
  local name, extra = title(f)
  local dur = f.duration or fights.duration(f)
  local mine = f.actors[me]
  return {
    id = f.id, name = name, extra = extra, live = live == true, duration = dur, total = f.total, taken = f.taken,
    dps = f.total / dur, kills = f.kills, deaths = #(f.deaths or {}), zone = f.zone or "",
    when = f.wall and os.date("%H:%M", f.wall) or "", ago = ago(f.wall), count = f.count,
    my_damage = mine and mine.damage or 0, my_dps = mine and mine.damage / dur or 0,
  }
end

local session_cache, session_rev = nil, -1

-- The session (every fight kept, and the one going on, as one), made again only when a fight changed.
local function session()
  if session_rev ~= F.rev or not session_cache then
    session_cache, session_rev = fights.session(F), F.rev
  end
  return session_cache
end

local function view_fight()
  if S.view == "session" then return session(), false end
  if F.current and F.current.total > 0 then return F.current, true end
  return F.history[1], false
end

local function spark(f, n)
  local out = {}
  local tl = f.timeline or {}
  local last = #tl
  if f == F.current then last = math.max(last, math.floor((mq.gettime() - f.start) / 1000) + 1) end
  for i = math.max(1, last - n + 1), last do out[#out + 1] = tl[i] or 0 end
  return out
end

hs.ui_function("state", function()
  local f, live = view_fight()
  local out = {
    open = open, details_open = details_open, rev = rev, list_rev = F.rev, me = me,
    fighting = F.current ~= nil and F.current.total > 0, settings = S, rates = rates_view(),
  }
  if f then
    out.fight = head(f, live)
    out.rows = fights.ranked(f)
    while #out.rows > S.rows do table.remove(out.rows) end
    if f.id ~= 0 then out.spark = spark(f, 40) end
  end
  return out
end)

-- The fights kept, newest first, the one going on at the top.
hs.ui_function("list", function()
  local out = {}
  if F.current and F.current.total > 0 then out[#out + 1] = head(F.current, true) end
  for _, f in ipairs(F.history) do out[#out + 1] = head(f, false) end
  return out
end)

-- Everything about one fight (0: the session).
hs.ui_function("fight", function(id)
  id = tonumber(id) or 0
  local f = id == 0 and session() or fights.find(F, id)
  if not f then return nil end
  local live = f == F.current
  local out = {
    head = head(f, live), damage = fights.ranked(f, "damage"), taken = fights.ranked(f, "taken"),
    mobs = fights.mobs(f), timeline = f.timeline or {}, series = {},
  }
  if id ~= 0 then
    -- the top five's own second-by-second damage, for the graph
    for i = 1, math.min(5, #out.damage) do
      local a = f.actors[out.damage[i].name]
      out.series[i] = { name = a.name, class = a.class, timeline = a.timeline or {} }
    end
  end
  return out
end)

hs.ui_function("abilities", function(id, name)
  id = tonumber(id) or 0
  local f = id == 0 and session() or fights.find(F, id)
  if not f or type(name) ~= "string" then return {} end
  return fights.abilities(f, name)
end)

hs.ui_function("set", function(key, value) return set(key, value) end)

hs.ui_function("command", function(what, arg)
  if what == "close" then open = false
  elseif what == "details" then details_open = not details_open
  elseif what == "close_details" then details_open = false
  elseif what == "end" then
    if fights.finish(F) then history_dirty = mq.gettime() end
  elseif what == "clear" then
    fights.clear(F)
    history_dirty = mq.gettime()
  elseif what == "reset_rates" then reset_rates()
  elseif what == "delete" then
    if fights.remove(F, tonumber(arg) or -1) then history_dirty = mq.gettime() end
  end
  return true
end)
hs.menu("DPS Meter", "/dps show")

-- ---------------------------------------------------------------- the command

mq.bind('/dps', function(a)
  a = (a or ""):lower()
  if a == "" or a == "show" then open = not open
  elseif a == "details" or a == "history" then details_open = not details_open
  elseif a == "end" then
    if fights.finish(F) then history_dirty = mq.gettime() say("fight ended.") else say("no fight going on.") end
  elseif a == "clear" then
    fights.clear(F)
    history_dirty = mq.gettime()
    say("fights cleared.")
  elseif a == "reset" then
    reset_rates()
    say("platinum and AA per hour start again from now.")
  elseif a == "rates" then
    local r = rates_view()
    say(string.format("since %s: %.1f platinum (%.1f looted, %.1f sold; %s/hour), %.2f AA (%s/hour).", r.since,
      r.plat, r.looted, r.sold, r.plat_hour and string.format("%.0f", r.plat_hour) or "-", r.aa,
      r.aa_hour and string.format("%.2f", r.aa_hour) or "-"))
  elseif a == "everyone" or a == "group" then
    set("who", a)
    say(a == "everyone" and "counting every player." or "counting you, your group and pets.")
  else
    say("/dps [show | details | end | clear | rates | reset | everyone | group]")
  end
end)

-- ---------------------------------------------------------------- the lines

mq.event('dpsmeter', '#*#', function(line)
  if rates.line(R, line) then return end
  local ev = parse.line(line)
  if not ev then return end
  ctx.me = me
  ctx.wall = os.time()
  ctx.zone = mq.TLO.Zone.Name() or ""
  fights.event(F, ev, mq.gettime(), ctx)
end)

-- ---------------------------------------------------------------- the loop

while true do
  local now = mq.gettime()
  load_all()
  local p = hs.player()
  local z = p and p.zone_id or 0
  if z ~= zone then
    -- a new zone: the fight there is over, and its names mean nothing here
    if fights.finish(F) then history_dirty = now end
    zone = z
    by_name, by_id = {}, {}
    spawns_at = -1e9
  end
  if now - spawns_at > SPAWNS_MS then read_spawns(now) end
  if now - aa_at > AA_MS then
    aa_at = now
    rates.aa_sample(R, mq.TLO.Me.AAPoints(), mq.TLO.Me.PctAAExp())
  end
  mq.doevents()
  if fights.tick(F, mq.gettime()) then history_dirty = mq.gettime() end
  save_due(now)
  mq.delay(TICK_MS)
end
