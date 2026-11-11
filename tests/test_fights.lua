local parse = require('lib.parse')
local fights = require('lib.fights')

-- Me (Bard), a group member Soandso, her pet, a stranger and two gnolls.
local WHO = {
  Me = { side = "me", class = 8 },
  Soandso = { side = "friend", class = 13 },
  ["Soandso`s warder"] = { side = "friend", owner = "Soandso" },
  Stranger = { side = "other" },
  ["a gnoll"] = { side = "enemy" },
  ["a gnoll scout"] = { side = "enemy" },
}
local ctx = { me = "Me", wall = 1000, zone = "qeynos2",
  classify = function(name)
    -- as the script does: a name at a sentence's start may be capitalised
    local w = WHO[name]
    if w then return w end
    local low = name:sub(1, 1):lower() .. name:sub(2)
    if WHO[low] then
      local c = {}
      for k, v in pairs(WHO[low]) do c[k] = v end
      c.name = low
      return c
    end
    return { side = "other" }
  end }

local function feed(F, now, line)
  return fights.event(F, parse.line(line), now, ctx)
end

case("fights: a fight starts with our first hit, adds up damage and ends when quiet", function()
  local F = fights.new({ idle_ms = 5000 })
  eq(feed(F, 0, "You try to hit a gnoll, but miss!"), false, "a miss starts nothing")
  eq(F.current, nil)
  eq(feed(F, 1000, "You slash a gnoll for 100 points of damage."), true)
  check(F.current ~= nil, "started")
  feed(F, 1500, "You try to hit a gnoll, but miss!")
  feed(F, 2500, "Soandso hit a gnoll for 300 points of non-melee damage.")
  feed(F, 3000, "Soandso`s warder bites a gnoll scout for 50 points of damage.")
  feed(F, 3200, "A gnoll hits YOU for 40 points of damage.")
  feed(F, 3300, "Stranger slashes a gnoll for 999 points of damage.")
  feed(F, 3400, "Soandso scores a critical hit! (77)")
  local f = F.current
  eq(f.total, 450, "the stranger is not counted")
  eq(f.actors.Soandso.damage, 350, "the pet's damage goes to its owner")
  eq(f.actors.Soandso.pet, 50)
  eq(f.actors.Soandso.crits, 1)
  eq(f.actors.Me.misses, 1)
  eq(f.actors.Me.taken, 40)
  eq(f.taken, 40)
  eq(f.mobs["a gnoll"].dealt, 40)
  eq(f.timeline[1], 100, "second 1") eq(f.timeline[2], 300, "second 2") eq(f.timeline[3], 50, "second 3")
  eq(fights.duration(f), 2.2, "first to last hit, taken ones too")
  eq(fights.tick(F, 7000), nil, "not yet quiet")
  local done = fights.tick(F, 8300)
  check(done ~= nil, "ended")
  eq(F.current, nil)
  eq(done.name, "a gnoll", "named after the mob that took the most")
  eq(done.extra, 1)
  eq(#F.history, 1)

  local r = fights.ranked(done)
  eq(r[1].name, "Soandso") eq(r[2].name, "Me")
  eq(r[2].accuracy, 50, "one hit, one miss")
  eq(math.floor(r[1].pct + 0.5), 78)
  local ab = fights.abilities(done, "Soandso")
  eq(ab[1].name, "Spells") eq(ab[2].name, "Pet: Bite")
  local taken = fights.ranked(done, "taken")
  eq(#taken, 1) eq(taken[1].name, "Me")
end)

case("fights: a kill ends the fight sooner; pets kept apart when asked", function()
  local F = fights.new({ idle_ms = 6000, after_kill_ms = 2000, merge_pets = false })
  feed(F, 0, "Soandso`s warder bites a gnoll for 50 points of damage.")
  feed(F, 500, "You have slain a gnoll!")
  eq(F.current.kills, 1)
  check(F.current.mobs["a gnoll"].killed, "killed")
  eq(F.current.actors["Soandso`s warder"].damage, 50, "the pet on its own")
  eq(fights.tick(F, 2000), nil)
  check(fights.tick(F, 2600) ~= nil, "ended after the kill")
end)

case("fights: Triune pet proc and player spells count with their spell names", function()
  -- Pet spawn data may not have arrived yet. The server's owner annotation still identifies our pet.
  local triune = { me = "Tripet", wall = 1000, zone = "gukbottom",
    classify = function(name)
      if name == "Tripet" then return { side = "me", name = name } end
      if name == "a wan ghoul knight" then return { side = "enemy", name = name } end
      return { side = "other" }
    end }
  local proc = "Frost (Owner: Tripet) hit a wan ghoul knight for 108 points of non-melee damage. (Spirit of Inferno Strike)"
  local bolt = "Tripet hit a wan ghoul knight for 59 points of non-melee damage. (Bolt of Flame)"
  local F = fights.new()
  eq(fights.event(F, parse.line(proc), 1000, triune), true)
  eq(fights.event(F, parse.line(bolt), 2000, triune), true)
  local f = F.current
  check(f ~= nil)
  eq(f.total, 167) eq(f.actors.Tripet.damage, 167) eq(f.actors.Tripet.pet, 108)
  eq(f.actors.Tripet.hits, 2)
  eq(f.actors.Tripet.abilities["Pet: Spirit of Inferno Strike"].damage, 108)
  eq(f.actors.Tripet.abilities["Bolt of Flame"].damage, 59)
  eq(fights.event(F, parse.line("Frost begins to cast a spell."), 2500, triune), false)
  eq(f.total, 167, "cast starts do not add estimated damage")

  local G = fights.new({ merge_pets = false })
  eq(fights.event(G, parse.line(proc), 1000, triune), true)
  eq(G.current.actors.Frost.damage, 108)
  eq(G.current.actors.Tripet, nil)
  eq(G.current.actors.Frost.abilities["Spirit of Inferno Strike"].damage, 108)
end)

case("fights: Triune ownership respects group scope", function()
  local F = fights.new()
  eq(feed(F, 0, "Unknown Pet (Owner: Soandso) hit a gnoll for 20 points of non-melee damage. (Test Proc)"), true)
  eq(F.current.actors.Soandso.pet, 20)
  eq(feed(F, 1, "Unknown Pet (Owner: Stranger) hit a gnoll for 99 points of non-melee damage. (Test Proc)"), false)
  eq(F.current.total, 20, "strangers' pets are not part of the group")
  eq(feed(F, 2, "Unknown Pet (Owner: You) hit a gnoll for 10 points of non-melee damage. (Test Proc)"), true)
  eq(F.current.actors.Me.pet, 10)
end)

case("fights: Triune ownership follows everyone scope without changing spawn data", function()
  local pet = { side = "enemy", name = "Unknown Pet" }
  local everyone = { me = ctx.me, wall = ctx.wall, zone = ctx.zone,
    classify = function(name)
      if name == "Unknown Pet" then return pet end
      if name == "Stranger" then return { side = "friend", name = "Stranger" } end
      return ctx.classify(name)
    end }
  local F = fights.new()
  local e = parse.line("Unknown Pet (Owner: Stranger) hit a gnoll for 99 points of non-melee damage. (Test Proc)")
  eq(fights.event(F, e, 0, everyone), true)
  eq(F.current.actors.Stranger.pet, 99)
  eq(pet.side, "enemy", "classification data is not mutated")
  eq(pet.owner, nil)
end)

case("fights: history is capped, sessions add up, restore renumbers", function()
  local F = fights.new({ max_history = 2 })
  for i = 1, 3 do
    feed(F, i * 100000, "You slash a gnoll for " .. (i * 10) .. " points of damage.")
    fights.finish(F)
  end
  eq(#F.history, 2)
  eq(F.history[1].total, 30, "newest first")
  local s = fights.session(F)
  eq(s.total, 50) eq(s.count, 2) eq(s.actors.Me.hits, 2)
  eq(fights.remove(F, F.history[2].id), true)
  eq(#F.history, 1)

  local G = fights.new()
  G.next_id = 1
  fights.restore(G, { { id = 41, total = 5, actors = {}, mobs = {}, start = 0, last = 0 }, "junk" })
  eq(#G.history, 1)
  eq(G.next_id, 42)
  feed(G, 0, "You slash a gnoll for 1 point of damage.")
  eq(G.current.id, 42)
  check(fights.find(G, 41) ~= nil, "found")
end)

case("fights: a fight with only damage taken is dropped", function()
  local F = fights.new()
  feed(F, 0, "A gnoll hits YOU for 40 points of damage.")
  check(F.current ~= nil, "a hit on us starts one")
  eq(fights.finish(F), nil)
  eq(#F.history, 0)
end)
