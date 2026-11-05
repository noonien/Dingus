-- Tests for Ding's protocol and rate logic, outside the game.
-- From the addon folder: nix-shell -p lua5_1 --run 'lua tests/run.lua'

local clock = 1000
GetTime = function() return clock end
time = function() return 1800000000 + clock end
C_Timer = { After = function() end, NewTicker = function() return { Cancel = function() end } end }
CreateFrame = function()
    return { RegisterEvent = function() end, UnregisterEvent = function() end, SetScript = function() end }
end

local ns = {}
local function Load(path)
    local chunk = assert(loadfile(path))
    chunk("Ding", ns)
end
Load("Core.lua")
Load("Comm.lua")
ns.UI = { Refresh = function() end, ShowLevelUp = function(_, peer) ns.alerted = peer end }
ns.Roster = { GuildName = function() return "Guild" end }
Load("Tracker.lua")
ns.db = ns.InitDB({})
ns.settings = ns.db.settings

local P, T = ns.Protocol, ns.Tracker
local R = T.Rate
local passed, failed = 0, 0

local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL " .. name .. "\n  " .. tostring(err))
    end
end

local function eq(actual, expected, what)
    if actual ~= expected then
        error((what or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

local STATUS = { seq = 1800000000, level = 41, xp = 81216, xpMax = 112800, rested = 13536,
                 class = "MAGE", name = "Mira Vale", zone = "Tanaris", questXP = 9024 }

test("status round trip", function()
    local m = P.Decode(P.EncodeStatus(STATUS))
    eq(m.kind, "S")
    for _, field in ipairs({ "seq", "level", "xp", "xpMax", "rested", "class", "name", "zone", "questXP" }) do
        eq(m[field], STATUS[field], field)
    end
end)

test("status without a zone", function()
    local copy = {}
    for k, v in pairs(STATUS) do copy[k] = v end
    copy.zone = nil
    local m = P.Decode(P.EncodeStatus(copy))
    eq(m.zone, nil)
    eq(m.questXP, 9024, "fields after an empty zone still line up")
end)

test("a missing or bad quest xp field reads as none", function()
    eq(P.Decode("1~S~1~41~1~2~0~MAGE~Ana").questXP, 0)
    eq(P.Decode("1~S~1~41~1~2~0~MAGE~Ana~Zone~nope").questXP, 0)
end)

test("hello and ping round trip", function()
    eq(P.Decode(P.EncodeHello()).kind, "H")
    eq(P.Decode(P.EncodePing(42)).nonce, 42)
    eq(P.Decode(P.EncodePong(42)).kind, "E")
end)

test("longest possible messages fit in 255 bytes", function()
    local long = string.rep("x", 300)
    local status = P.EncodeStatus({ seq = 2147483647, level = 255, xp = 2147483647, xpMax = 2147483647,
        rested = 2147483647, class = "DEATHKNIGHTXXXXXXXXX", name = long, zone = long, questXP = 2147483647 })
    assert(#status <= 255, "status is " .. #status)
    assert(P.Decode(status), "long status decodes")
end)

test("malformed input is rejected", function()
    local bad = {
        "", "~", "1", "1~", "1~Z", "2~H", "garbage",
        "1~S", "1~S~1~41~1~1~1~MAGE",             -- no name
        "1~S~x~41~1~1~1~MAGE~Ana",                -- bad seq
        "1~S~1~0~1~1~1~MAGE~Ana",                 -- level 0
        "1~S~1~999~1~1~1~MAGE~Ana",               -- level too high
        "1~S~1~41~-5~1~1~MAGE~Ana",               -- negative
        "1~S~1~41~1.5~1~1~MAGE~Ana",              -- fraction
        "1~S~1~41~99999999999~1~1~MAGE~Ana",      -- overflow
        "1~S~1~41~1~1~1~mage~Ana",                -- class casing
        "1~S~1~41~1~1~1~MA|GE~Ana",               -- class bytes
        "1~S~1~41~1~1~1~MAGE~   ",                -- blank name
        "1~Q~1~Ana~x~5",                          -- bad quest id
        "1~D~nope",
        string.rep("1", 256),
    }
    for _, text in ipairs(bad) do
        eq(P.Decode(text), nil, "decode of [" .. text .. "]")
    end
    eq(P.Decode(nil), nil)
    eq(P.Decode(5), nil)
end)

test("xp above the level's maximum is clamped", function()
    eq(P.Decode("1~S~1~41~500~100~0~MAGE~Ana").xp, 100)
end)

test("text fields lose escape codes and control bytes", function()
    local m = P.Decode("1~S~1~41~1~2~0~MAGE~Ana|TInterface\\x:0|t Smith~Zo\1ne\n")
    assert(not m.name:find("|", 1, true), "pipe in name")
    eq(m.zone, "Zone")
    eq(P.CleanText("a\0b", 10), "ab")
    eq(P.CleanText("  ", 10), nil)
    eq(P.CleanText(5, 10), nil)
end)

test("cleaning doesn't split a UTF-8 character", function()
    eq(P.CleanText("ab\195\169cd", 3), "ab")
    eq(P.CleanText("ab\195\169cd", 4), "ab\195\169")
    eq(P.CleanText("\226\130\172", 2), nil)
end)

test("name comparison", function()
    assert(P.SameName("Ana Smith", "ana smith"))
    assert(P.SameName("Ana", "Ana Smith"))
    assert(P.SameName("Ana-Realm", "Ana Smith"))
    assert(not P.SameName("Ana Smith", "Ana Jones"))
    assert(not P.SameName("Ana Smith", "Mira Vale"))
    assert(not P.SameName(nil, "Ana"))
end)

test("status dedupe", function()
    local rt = {}
    assert(T.AcceptStatus(rt, 10))
    assert(not T.AcceptStatus(rt, 10), "repeat")
    assert(not T.AcceptStatus(rt, 9), "older")
    assert(T.AcceptStatus(rt, 11))
end)

test("rate over steady gains", function()
    local r = R.New()
    R.Add(r, 0, 10, 0, 1000)
    R.Add(r, 300, 10, 100, 1000)
    R.Add(r, 600, 10, 200, 1000)
    eq(R.Get(r, 600), 1200)
    eq(R.TimeToLevel(1200, 200, 1000), 2400)
end)

test("rate across a level-up", function()
    local r = R.New()
    R.Add(r, 0, 10, 900, 1000)
    R.Add(r, 360, 11, 50, 2000)
    eq(R.Get(r, 360), 1500)
end)

test("rate needs gains, and uses a minimum span", function()
    local r = R.New()
    eq(R.Get(r, 0), nil)
    R.Add(r, 0, 10, 5, 1000)
    eq(R.Get(r, 0), nil)
    R.Add(r, 10, 10, 15, 1000)
    eq(R.Get(r, 10), 600)
end)

test("xp earned during a long gap isn't a spike", function()
    local r = R.New()
    R.Add(r, 0, 10, 0, 1000)
    R.Add(r, 5000, 10, 900, 1000)
    eq(R.Get(r, 5000), nil)
    R.Add(r, 5060, 10, 960, 1000)
    eq(R.Get(r, 5060), 3600)
end)

test("old samples don't pile up", function()
    local r = R.New()
    for i = 0, 10000 do R.Add(r, i * 60, 10, i, 1000000) end
    assert(#r.samples <= 16, "samples: " .. #r.samples)
end)

test("rate goes quiet after the window", function()
    local r = R.New()
    R.Add(r, 0, 10, 0, 1000)
    R.Add(r, 60, 10, 100, 1000)
    eq(R.Get(r, 60 + R.WINDOW + 1), nil)
end)

test("time to level edge cases", function()
    eq(R.TimeToLevel(nil, 1, 2), nil)
    eq(R.TimeToLevel(0, 1, 2), nil)
    eq(R.TimeToLevel(100, 1, 0), nil)
end)

test("number and time formatting", function()
    eq(T.FormatNumber(0), "0")
    eq(T.FormatNumber(999), "999")
    eq(T.FormatNumber(1000), "1,000")
    eq(T.FormatNumber(1234567), "1,234,567")
    eq(T.FormatNumber(1240.7), "1,240")
    eq(T.FormatShort(950), "950")
    eq(T.FormatShort(35500), "35.5k")
    eq(T.FormatShort(44300), "44.3k")
    eq(T.FormatShort(1260000), "1.3m")
    eq(T.FormatDuration(30), "<1m")
    eq(T.FormatDuration(2940), "49m")
    eq(T.FormatDuration(9120), "2h 32m")
    eq(T.FormatDuration(500000), "100h+")
    eq(T.FormatAgo(12), "12s")
    eq(T.FormatAgo(180), "3m")
    eq(T.FormatAgo(10800), "3h")
    eq(T.FormatAgo(172800), "2d")
end)

test("sorting: pinned, then online, then the chosen order", function()
    local function e(key, name, level, xp, online, seen)
        return { peer = { key = key, name = name, level = level, xp = xp, xpMax = 100, seen = seen }, online = online }
    end
    local a, b, c, d = e("a", "Ana", 40, 10, true, 5), e("b", "Bo", 50, 90, false, 9),
        e("c", "Cy", 30, 50, true, 7), e("d", "Di", 10, 0, false, 1)
    local list = { a, b, c, d }
    T.SortEntries(list, "level", { d = true })
    eq(list[1], d, "pinned") eq(list[2], a, "online high") eq(list[3], c, "online low") eq(list[4], b, "offline")
    T.SortEntries(list, "progress", {})
    eq(list[1], c) eq(list[2], a)
    T.SortEntries(list, "recent", {})
    eq(list[1], c) eq(list[2], a)
    T.SortEntries(list, "name", {})
    eq(list[1], a) eq(list[2], c) eq(list[3], b) eq(list[4], d)
end)

test("status updates a peer, and only a fresh level-up alerts", function()
    ns.alerted = nil
    local route = { kind = "guild" }
    T:OnStatus(P.Decode("1~S~100~41~50~100~10~MAGE~Mira Vale~Tanaris"), route)
    local peer = ns.db.peers["mira vale"]
    eq(peer.level, 41) eq(peer.xp, 50) eq(peer.zone, "Tanaris") eq(peer.guild, "Guild")
    eq(ns.alerted, nil, "first sighting")

    T:OnStatus(P.Decode("1~S~100~42~1~100~10~MAGE~Mira Vale"), route)
    eq(peer.level, 41, "repeat sequence ignored")

    clock = clock + 60
    T:OnStatus(P.Decode("1~S~101~42~1~100~10~MAGE~Mira Vale"), route)
    eq(peer.level, 42)
    eq(peer.zone, nil, "zone cleared when no longer shared")
    assert(ns.alerted == peer, "alerted")

    ns.alerted = nil
    clock = clock + 5000
    T:OnStatus(P.Decode("1~S~102~43~1~100~10~MAGE~Mira Vale"), route)
    eq(ns.alerted, nil, "level gained while unseen")
end)

test("completed quest xp reaches the peer", function()
    T:OnStatus(P.Decode("1~S~500~43~1~100~10~MAGE~Mira Vale~~40"), { kind = "guild" })
    eq(ns.db.peers["mira vale"].questXP, 40)
end)

test("old saved settings move to the new defaults once", function()
    local db = ns.InitDB({ settings = { opacity = 0.46, collapsed = true } })
    eq(db.settings.opacity, 0, "background removed")
    eq(db.settings.collapsed, nil, "header state gone")
    eq(db.schema, 5)
    db.settings.opacity = 0.3
    eq(ns.InitDB(db).settings.opacity, 0.3, "a value set afterwards stays")
    eq(ns.InitDB({ schema = 4, settings = { showGuild = true } }).settings.showGuild, false, "guild reset once")
    eq(ns.InitDB({ schema = 5, settings = { showGuild = true } }).settings.showGuild, true, "turned on afterwards stays")
    eq(ns.InitDB({}).settings.showGuild, false, "new install")
    eq(ns.InitDB({}).settings.opacity, 0, "new install")
end)

test("old row sizes move to the thick-bar defaults, chosen ones stay", function()
    local old = ns.InitDB({ schema = 2, settings = { width = 268, barHeight = 24, spacing = 4, fontSize = 13 } }).settings
    eq(old.width, 300) eq(old.barHeight, 22) eq(old.spacing, 1) eq(old.fontSize, 12)
    local chosen = ns.InitDB({ schema = 2, settings = { width = 350, barHeight = 30, spacing = 3, fontSize = 15 } }).settings
    eq(chosen.width, 350) eq(chosen.barHeight, 30) eq(chosen.spacing, 3) eq(chosen.fontSize, 15)
end)

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
