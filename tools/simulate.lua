-- Runs example scenarios in the simulated edge client and prints what the app does, minute by minute:
--   lua5.3 tools/simulate.lua
-- Nothing is sent anywhere. All names, addresses and numbers are made up.

local S = dofile("tests/sim.lua")

local function mmss(sim) local s = sim.clock - S.T0 return string.format("%3d:%02d", s // 60, s % 60) end

local function watch(sim)
  local seen_pub, seen_notify, seen_log = 0, 0, 0
  return function()
    for i = seen_log + 1, #sim.logs do
      local l = sim.logs[i]
      if not l:match("^I toolong") then print(mmss(sim) .. "  log      " .. l:sub(3)) end
    end
    for i = seen_pub + 1, #sim.published do
      local p = sim.published[i]
      if not p.topic:match("^obj/toolong/") then
        local v = S.json:decode(p.payload).value
        print(mmss(sim) .. "  publish  " .. p.topic .. " = " .. tostring(v))
      end
    end
    for i = seen_notify + 1, #sim.notified do
      local n = sim.notified[i]
      local b = n.body
      print(string.format("%s  notify   output %d: %s, %d min, step %d%s%s, to %s / %s", mmss(sim), n.id, b.label, b.minutes, b.step,
        b["repeat"] > 0 and (" repeat " .. b["repeat"]) or "",
        b.control and (" (valve confirmed: " .. tostring(b.control.confirmed) .. ")") or "",
        b.recipients_email or "-", b.recipients_sms or "-"))
    end
    seen_pub, seen_notify, seen_log = #sim.published, #sim.notified, #sim.logs
  end
end

local function run(title, opts, script)
  print("\n== " .. title)
  local _, env, sim = S.load_app(opts or {})
  local show = watch(sim)
  env.onStart()
  local value = sim.value
  sim.value = function(topic, v) print(string.format("%s  value    %s = %s", mmss(sim), topic, tostring(v))) value(topic, v) show() end
  script(sim, function(secs)
    for _ = 1, secs // 5 do sim.advance(5) show() end
    sim.advance(secs % 5) show()
  end)
  show()
end

run("Vatten i köket: kallvattnet rinner i 25 min, ventilen bekräftar", nil, function(sim, wait)
  wait(30)
  sim.value(S.COLD, 1)
  wait(20 * 60 + 3)
  sim.value("obj/knx/0/2/40", 1) -- the valve reports closed
  wait(5 * 60)
  sim.value(S.COLD, 0)
  wait(60)
end)

run("Kyl och frys: kylskåpet står öppet, påminnelse var 2:a min", {
  functions = { S.water(201, "obj/knx/0/1/24", { name = "Dörr Kylskåp", ["toolong.label"] = "kylskåpsdörren", ["toolong.group"] = "kitchen-water", ["toolong.sound"] = "iotopen/fridge-open.mp3" }) },
  cfg = S.config({ name = "Kyl och frys", steps = {
    { step_after_min = 5, step_sound = true, step_repeat_every_min = 2, step_max_repeats = 3 },
    { step_after_min = 10, step_outputs = { 1003 }, step_recipient_group = "staff", step_repeat_every_min = 15 },
  } }),
}, function(sim, wait)
  sim.value("obj/knx/0/1/24", 1)
  wait(12 * 60)
  sim.value("obj/knx/0/1/24", 0)
  wait(30)
end)

run("Dörrlarm bara i läget Borta: dörren står öppen när läget byts", {
  extra_functions = { S.MODE },
  functions = { S.water(301, "obj/knx/0/1/22", { name = "Dörr Altan", ["toolong.label"] = "altandörren", ["toolong.group"] = "kitchen-water" }) },
  cfg = S.config({ name = "Dörrar när ingen är hemma", active_modes = "away, vacation", steps = {
    { step_after_min = 10, step_outputs = { 1003 }, step_recipient_group = "staff" },
  } }),
}, function(sim, wait)
  sim.value("obj/mode/default", 0)
  sim.value("obj/knx/0/1/22", 1)
  wait(15 * 60)
  sim.value("obj/mode/default", 1)
  wait(30)
end)
