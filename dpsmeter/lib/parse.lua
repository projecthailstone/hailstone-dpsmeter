-- One chat line as a combat event, or nil. Pure: no game state, so it is tested with plain Lua.
--
-- The lines are the ones a stock EQEmu server and the Hailstone client print with the hit display modes left at
-- their default (full sentences). The templates, by eqstr id (the server's zone/string_ids.h names):
--   melee   12162 "%1 %2 %3 %4" with 12160 / 12161 "for %1 point(s) of damage."   the client, from OP_Damage
--           12158 / 12159 "%1 try / tries to %2 %3, but %4!"                     a miss, block, parry ...
--   spells  9073  HIT_NON_MELEE       "%1 hit %2 for %3 points of non-melee damage."
--           434   OTHER_HIT_NONMELEE  "%1 was hit by non-melee for %2 points of damage."   your damage shield
--   DoTs    9072  YOUR_HIT_DOT        "%1 has taken %2 damage from your %3."
--           13327 OTHER_HIT_DOT       "%1 has taken %2 damage from %3 by %4."
--           12954 YOU_TAKE_DOT        "You have taken %1 damage from %2 by %3"
--   crits   1023 CRITICAL_HIT, 1021 CRIPPLING_BLOW, 1024 DEADLY_STRIKE, 428 YOU_CRIT_BLAST, 1040 OTHER_CRIT_BLAST
--   deaths  12113 "You have slain %1!", 12114 "%1 has been slain by %2!", 12107 "You have been slain by %1!"
--
-- Every event names its actors as the line does, except the player, who is parse.ME ("You", "YOU", "yourself").
-- A short hit display mode (the number alone, or "hit a rat for 5") is not read: those lines carry no attacker.
local parse = {}

parse.ME = "\1me"

-- The melee verbs (eqstr 12163..12202, 5838 / 5839), first and third person, longest first where one starts
-- another ("frenzies on" before a lone word).
local VERBS = {
  "frenzy on", "frenzies on",
  "hit", "hits", "slash", "slashes", "crush", "crushes", "pierce", "pierces", "kick", "kicks", "strike", "strikes",
  "backstab", "backstabs", "bash", "bashes", "punch", "punches", "bite", "bites", "claw", "claws", "maul", "mauls",
  "sting", "stings", "slice", "slices", "gore", "gores", "smash", "smashes", "rend", "rends",
}
local VERB_SET = {}
for _, v in ipairs(VERBS) do VERB_SET[v] = true end

-- The base form for a verb, so "slash" and "slashes" count as one attack ("frenzies on" -> "frenzy on").
local BASE = {
  hits = "hit", slashes = "slash", crushes = "crush", pierces = "pierce", kicks = "kick", strikes = "strike",
  backstabs = "backstab", bashes = "bash", punches = "punch", bites = "bite", claws = "claw", mauls = "maul",
  stings = "sting", slices = "slice", gores = "gore", smashes = "smash", rends = "rend",
  ["frenzies on"] = "frenzy on",
}
function parse.base_verb(v) return BASE[v] or v end

local function who(name)
  if name == "You" or name == "YOU" or name == "you" or name == "yourself" or name == "Yourself" then return parse.ME end
  return name
end

-- "a gnoll pup slashes a rat" -> "a gnoll pup", "slashes", "a rat": the first verb that has a name on both sides.
local function split_attack(s)
  local words = {}
  for w in s:gmatch("%S+") do words[#words + 1] = w end
  for i = 2, #words - 1 do
    local two = i < #words - 1 and (words[i] .. " " .. words[i + 1]) or nil
    if two and VERB_SET[two] then
      return table.concat(words, " ", 1, i - 1), two, table.concat(words, " ", i + 2)
    end
    if VERB_SET[words[i]] then
      return table.concat(words, " ", 1, i - 1), words[i], table.concat(words, " ", i + 1)
    end
  end
  return nil
end

local function num(s) return tonumber((s:gsub(",", ""))) end

-- Triune adds an owner to pet sources and a spell name after the stock damage sentence.
local function spell(s, t, n, ability)
  local pet, owner = s:match("^(.+) %(Owner: (.+)%)$")
  return { kind = "spell", src = who(pet or s), owner = owner and who(owner), dst = who(t),
    amount = num(n), ability = ability or "Spells" }
end

-- Each rule: a Lua pattern and what to make of its captures. Tried in order; the first match wins, so the specific
-- shapes come before the melee one (434 also ends "for %2 points of damage.").
local RULES = {
  { "^You have slain (.+)!$", function(v) return { kind = "death", victim = v, killer = parse.ME } end },
  { "^You have been slain by (.+)!$", function(k) return { kind = "death", victim = parse.ME, killer = who(k) } end },
  { "^(.+) has been slain by (.+)!$", function(v, k)
    if k == "an unseen hand" then k = nil end
    return { kind = "death", victim = who(v), killer = k and who(k) }
  end },
  { "^(.+) has taken ([%d,]+) damage from your (.+)%.$", function(t, n, sp)
    return { kind = "dot", src = parse.ME, dst = who(t), amount = num(n), ability = sp }
  end },
  { "^(.+) has taken ([%d,]+) damage from (.+) by (.+)%.$", function(t, n, s, sp)
    return { kind = "dot", src = who(s), dst = who(t), amount = num(n), ability = sp }
  end },
  { "^You have taken ([%d,]+) damage from (.+) by (.+)$", function(n, s, sp)
    return { kind = "dot", src = who(s), dst = parse.ME, amount = num(n), ability = (sp:gsub("%.$", "")) }
  end },
  { "^(.+) was hit by non%-melee for ([%d,]+) points? of damage%.$", function(t, n)
    return { kind = "ds", src = parse.ME, dst = who(t), amount = num(n), ability = "Damage shield" }
  end },
  { "^(.+) hit (.+) for ([%d,]+) points? of non%-melee damage%. %((.+)%)$", spell },
  { "^(.+) hit (.+) for ([%d,]+) points? of non%-melee damage%.$", spell },
  { "^You deliver a critical blast! %(([%d,]+)%)$", function(n)
    return { kind = "crit", src = parse.ME, amount = num(n), what = "blast" }
  end },
  { "^(.+) delivers a critical blast! %(([%d,]+)%)$", function(s, n)
    return { kind = "crit", src = who(s), amount = num(n), what = "blast" }
  end },
  { "^(.+) scores a critical hit! %(([%d,]+)%)$", function(s, n)
    return { kind = "crit", src = who(s), amount = num(n), what = "melee" }
  end },
  { "^(.+) lands a Crippling Blow! ?%(([%d,]+)%)$", function(s, n)
    return { kind = "crit", src = who(s), amount = num(n), what = "melee" }
  end },
  { "^(.+) scores a Deadly Strike! ?%(([%d,]+)%)$", function(s, n)
    return { kind = "crit", src = who(s), amount = num(n), what = "melee" }
  end },
  { "^(.+) tr[iy]e?s? to (.+), but (.+)!$", function(s, rest, how)
    -- "You try to hit a rat, but miss!" / "A rat tries to bite YOU, but YOU parry!"
    local verb, t
    for _, v in ipairs(VERBS) do
      local tail = rest:match("^" .. v:gsub(" ", "%%s") .. " (.+)$")
      if tail and not BASE[v] then verb, t = v, tail break end
    end
    if not verb then return nil end
    local word = how:match("(%S+)$") or how
    return { kind = "miss", src = who(s), dst = who(t), ability = verb, how = word:lower() }
  end },
  { "^(.+) for ([%d,]+) points? of damage%.$", function(head, n)
    local s, v, t = split_attack(head)
    if not s then return nil end
    return { kind = "melee", src = who(s), dst = who(t), amount = num(n), ability = parse.base_verb(v) }
  end },
}

function parse.line(text)
  if type(text) ~= "string" or text == "" then return nil end
  for _, r in ipairs(RULES) do
    local caps = { text:match(r[1]) }
    if caps[1] ~= nil then
      local ev = r[2](table.unpack(caps))
      if ev then return ev end
    end
  end
  return nil
end

-- Spawn names as the chat shows them: "a_rat01" -> "a rat" (the client's game::display_name).
function parse.display_name(name)
  return ((tostring(name or ""):gsub("%d+$", "")):gsub("_", " "))
end

return parse
