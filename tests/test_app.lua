-- Tests for app.lua without an edge client: run with `lua5.3 tests/test_app.lua` from the repository root.
-- The edge client (cfg, app, log, json, lynx, mq, timer) and the clock are simulated, so a whole timeline of
-- minutes runs in milliseconds. All names, addresses and numbers are made up.

local failures, count = 0, 0

local function check(name, fn)
  count = count + 1
  local ok, err = pcall(fn)
  if ok then print("ok   " .. name) else failures = failures + 1 print("FAIL " .. name .. ": " .. tostring(err)) end
end

local function eq(a, b, what)
  if a ~= b then error(string.format("%s: expected %s, got %s", what or "value", tostring(b), tostring(a)), 2) end
end

local S = dofile("tests/sim.lua")
local json, T0, water, SPEAKER, PLAY, RECIPIENTS, config, load_app = S.json, S.T0, S.water, S.SPEAKER, S.PLAY, S.RECIPIENTS, S.config, S.load_app
local COLD, PLAYER, VALVE = S.COLD, S.PLAYER, S.VALVE

-- ---- settings ------------------------------------------------------------------------------------------------------

check("steps are sorted by time and steps without a time are left out", function()
  local M = load_app({})
  local s = M.settings(config({ steps = { { step_after_min = 20 }, { step_after_min = 0 }, { step_after_min = "5" }, { step_outputs = { 1 } } } }))
  eq(#s.steps, 3, "steps (0 = at once)")
  eq(s.steps[1].after_min, 0, "first")
  eq(s.steps[2].after_min, 5, "second")
  eq(s.steps[2].n, 2, "numbered after sorting")
  eq(s.steps[3].after_min, 20, "third")
end)

check("output selectors as a list or as a map of ids", function()
  local M = load_app({})
  local s = M.settings(config({ steps = { { step_after_min = 1, step_outputs = { 3, 1 } }, { step_after_min = 2, step_outputs = { ["7"] = true } } } }))
  eq(table.concat(s.steps[1].outputs, ","), "1,3", "list")
  eq(table.concat(s.steps[2].outputs, ","), "7", "map")
end)

check("the active value: function, instance, state_* or 1", function()
  local M = load_app({})
  local s = M.settings(config())
  eq(M.active_value({ meta = { ["toolong.active_value"] = "255", state_true = "1" } }, s), "255", "own")
  eq(M.active_value({ meta = { state_open = "1" } }, M.settings(config({ active_value = "on" }))), "on", "instance")
  eq(M.active_value({ meta = { state_open = "open" } }, s), "open", "state_open")
  eq(M.active_value({ meta = {} }, s), "1", "default")
  eq(M.label({ id = 3, meta = { name = "Kylskåp", ["toolong.label"] = "kylskåpsdörren" } }), "kylskåpsdörren", "label")
  eq(M.label({ id = 3, meta = { name = "Kylskåp" } }), "Kylskåp", "name")
end)

-- ---- the timeline --------------------------------------------------------------------------------------------------

check("kitchen water: sound and e-mail at 10 min, valve and both outputs at 20 min, all from time zero", function()
  local _, env, sim = load_app({})
  env.onStart()
  sim.advance(60)
  sim.value(COLD, 1)                         -- time zero
  sim.advance(9 * 60 + 50)
  eq(#sim.notified, 0, "nothing before 10 min")
  sim.advance(20)
  local n = sim.to(1001)
  eq(#n, 1, "step 1 notification")
  eq(n[1].body.label, "Kök kallvatten", "label")
  eq(n[1].body.minutes, 10, "minutes")
  eq(n[1].body.step, 1, "step")
  eq(n[1].body.instance, "Vatten i köket", "instance")
  eq(n[1].body.recipients_email, "anna@example.com,bo@example.com", "recipients from the group")
  eq(n[1].body.recipients_sms, "+46700000001", "sms recipients")
  eq(sim.pubs(PLAYER)[1].value, "iotopen/kitchen-water-running.mp3", "sound on the speaker")
  eq(#sim.pubs(VALVE), 0, "valve not yet")
  sim.advance(10 * 60)                       -- 20 min from time zero, not 20 after step 1
  eq(sim.pubs(VALVE)[1].value, 1, "valve closed")
  eq(#sim.to(1002), 0, "step 2 waits for the check")
  sim.advance(4)
  sim.value("obj/knx/0/2/40", 1)             -- the valve reports closed
  eq(#sim.to(1002), 1, "e-mail output")
  eq(#sim.to(1004), 1, "SMS output in parallel")
  eq(sim.to(1002)[1].body.control.confirmed, true, "confirmed")
  eq(sim.to(1002)[1].body.minutes, 20, "minutes")
  eq(#sim.pubs(PLAYER), 2, "second sound")
end)

check("a valve that does not confirm is reported", function()
  local _, env, sim = load_app({})
  env.onStart()
  sim.value(COLD, 1)
  sim.advance(20 * 60 + 5)
  eq(#sim.to(1002), 0, "waiting")
  sim.advance(40)
  eq(#sim.to(1002), 1, "sent after verify_s")
  eq(sim.to(1002)[1].body.control.confirmed, false, "not confirmed")
end)

check("commands are never repeated and the app never opens the valve", function()
  local _, env, sim = load_app({})
  env.onStart()
  sim.value(COLD, 1)
  sim.advance(60 * 60)
  sim.value(COLD, 0)
  sim.advance(60)
  local valve = sim.pubs(VALVE)
  eq(#valve, 1, "one command")
  eq(valve[1].value, 1, "only closing")
end)

check("a short pause does not reset the clock, a longer one does", function()
  local _, env, sim = load_app({})
  env.onStart()
  sim.value(COLD, 1)
  sim.advance(5 * 60)
  sim.value(COLD, 0)
  sim.advance(5)                              -- shorter than debounce_s = 10
  sim.value(COLD, 1)
  sim.advance(5 * 60 + 5)
  eq(#sim.to(1001), 1, "step 1 at 10 min from the first start")
  sim.value(COLD, 0)
  sim.advance(20)                             -- longer than debounce_s: reset
  sim.value(COLD, 1)
  sim.advance(9 * 60)
  eq(#sim.to(1001), 1, "new clock: nothing at 9 min")
  sim.advance(70)
  eq(#sim.to(1001), 2, "step 1 again at 10 min from the new time zero")
end)

check("two functions have clocks of their own and are listed together", function()
  local _, env, sim = load_app({ functions = { water(101, COLD), water(102, "obj/knx/0/1/11", { name = "Kök varmvatten" }) } })
  env.onStart()
  sim.value(COLD, 1)
  sim.advance(4 * 60)
  sim.value("obj/knx/0/1/11", 1)
  sim.advance(6 * 60 + 5)
  local n = sim.to(1001)
  eq(#n, 1, "only the cold water has reached 10 min")
  eq(n[1].body.active_count, 2, "both active")
  eq(n[1].body.active[1].label, "Kök kallvatten", "longest first")
  eq(n[1].body.active[2].minutes, 6, "the other one's minutes")
  sim.advance(4 * 60)
  eq(#sim.to(1001), 2, "the warm water's own step 1")
  eq(sim.to(1001)[2].body.label, "Kök varmvatten", "label")
end)

check("repeats every n minutes up to max_repeats, sound and notification but no command", function()
  local c = config({ steps = { { step_after_min = 5, step_sound = true, step_outputs = { 1003 }, step_repeat_every_min = 2, step_max_repeats = 3 } } })
  local _, env, sim = load_app({ cfg = c })
  env.onStart()
  sim.value(COLD, 1)
  sim.advance(30 * 60)
  local n = sim.to(1003)
  eq(#n, 4, "first + 3 repeats")
  eq(n[1].body["repeat"], 0, "first")
  eq(n[4].body["repeat"], 3, "third repeat")
  eq(n[2].at - n[1].at <= 125 and n[2].at - n[1].at >= 120, true, "2 min apart")
  eq(#sim.pubs(PLAYER), 4, "sounds")
end)

-- ---- restart, offline and the speaker -----------------------------------------------------------------------------

check("after a restart the clock goes on from the value's own timestamp", function()
  local _, env, sim = load_app({ status = { { topic = "4711/" .. COLD, value = 1, timestamp = T0 - 25 * 60 } } })
  env.onStart()
  sim.advance(10)
  eq(#sim.to(1001), 1, "missed step 1 sent once")
  eq(sim.to(1001)[1].body.minutes, 25, "minutes from the real time zero")
  eq(sim.pubs(VALVE)[1].value, 1, "missed command still sent: the water still runs")
end)

check("a restart without internet goes on from the saved clock, without repeating steps", function()
  local _, env, sim = load_app({})
  env.onStart()
  sim.value(COLD, 1)
  sim.advance(12 * 60)
  eq(#sim.to(1001), 1, "step 1 before the restart")
  -- the edge client restarts 3 minutes later, offline, and no new value comes (KNX values are not retained)
  local _, env2, sim2 = load_app({ cfg = sim.instance_config, retained = sim.retained, clock = sim.clock + 3 * 60, offline = true })
  env2.onStart()
  sim2.advance(4 * 60)
  eq(#sim2.to(1001), 0, "step 1 not sent again")
  eq(#sim2.pubs(VALVE), 0, "nothing before 20 min")
  sim2.advance(60 + 5)
  eq(sim2.pubs(VALVE)[1].value, 1, "step 2 at 20 min from the first time zero")
end)

check("a saved clock is ignored when IoT Open says the function is no longer active", function()
  local _, env, sim = load_app({})
  env.onStart()
  sim.value(COLD, 1)
  sim.advance(5 * 60)
  local _, env2, sim2 = load_app({ cfg = sim.instance_config, retained = sim.retained, clock = sim.clock + 60,
    status = { { topic = COLD, value = 0, timestamp = sim.clock + 30 } } })
  env2.lynx.getStatus = env2.lynx.getStatus
  env2.onStart()
  sim2.advance(30 * 60)
  eq(#sim2.notified, 0, "closed during the restart: no alarm")
end)

check("a missed sound older than an hour is skipped, the notification is not", function()
  local _, env, sim = load_app({ status = { { topic = COLD, value = 1, timestamp = T0 - 3 * 3600 } } })
  env.onStart()
  sim.advance(10)
  eq(#sim.to(1001), 1, "notification")
  eq(#sim.pubs(PLAYER), 0, "no sound for something 3 hours old")
end)

check("notifications that fail are queued, retried and marked late after an hour", function()
  local online_at = T0 + 2 * 3600
  local _, env, sim = load_app({ notify_fails = function(s) return s.clock < online_at end })
  env.onStart()
  sim.value(COLD, 1)
  sim.advance(11 * 60)
  eq(#sim.notified, 0, "offline")
  sim.advance(2 * 3600)
  local n = sim.to(1001)
  eq(#n, 1, "sent once when back")
  eq(n[1].body.late, true, "marked late")
  eq(n[1].body.minutes, 10, "minutes as when it happened")
end)

check("no speaker: sounds are skipped with one warning", function()
  local _, env, sim = load_app({ devices = { RECIPIENTS } })
  env.onStart()
  sim.value(COLD, 1)
  sim.advance(25 * 60)
  eq(#sim.pubs(PLAYER), 0, "no sound")
  local warnings = 0
  for _, l in ipairs(sim.logs) do if l:find("no speaker", 1, true) then warnings = warnings + 1 end end
  eq(warnings, 1, "one warning")
  eq(#sim.to(1001), 1, "notification still sent")
end)

check("the speaker: the chosen audio device, or the first one", function()
  local M = load_app({})
  local other = { id = 800, type = "audio", meta = {} }
  local play2 = { id = 801, meta = { ["ha.part"] = "play", device_id = "800", topic_write = "set/obj/ha/media_player/bedroom/play" } }
  eq(M.player_topic({ SPEAKER, other }, { PLAY, play2 }, nil), "set/obj/ha/media_player/bedroom/play", "first by id")
  eq(M.player_topic({ SPEAKER, other }, { PLAY, play2 }, 900), PLAYER, "chosen")
  eq(M.player_topic({ { id = 1, type = "HomeAssistant" } }, { PLAY }, nil), nil, "no audio device")
end)

check("a function's own sound wins over the default", function()
  local _, env, sim = load_app({ functions = { water(101, COLD, { ["toolong.sound"] = "iotopen/cold-water.mp3" }) } })
  env.onStart()
  sim.value(COLD, 1)
  sim.advance(10 * 60 + 5)
  eq(sim.pubs(PLAYER)[1].value, "iotopen/cold-water.mp3", "own sound")
end)

check("recipients from several devices are merged, a step without a group gets none", function()
  local M = load_app({})
  local r = M.recipients({ RECIPIENTS, { type = "recipients", meta = { recipients_email_staff = "cia@example.com,anna@example.com" } } }, "staff")
  eq(r.recipients_email, "anna@example.com,bo@example.com,cia@example.com", "merged")
  eq(next(M.recipients({ RECIPIENTS }, "")), nil, "no group")
  eq(M.recipients({ RECIPIENTS }, "night").recipients_email, nil, "unknown group")
end)

-- ---- the installation's mode ------------------------------------------------------------------------------------

check("steps wait while the mode is not in active_modes, the clock goes on", function()
  local _, env, sim = load_app({ extra_functions = { S.MODE }, cfg = config({ active_modes = "away, vacation" }) })
  env.onStart()
  sim.value("obj/mode/default", 0)          -- home
  sim.value(COLD, 1)
  sim.advance(15 * 60)
  eq(#sim.notified, 0, "nothing while home")
  sim.value("obj/mode/default", 1)          -- away
  sim.advance(5)
  local n = sim.to(1001)
  eq(#n, 1, "step 1 at once, from the right time")
  eq(n[1].body.minutes, 15, "minutes since time zero")
  eq(n[1].body.mode, "away", "mode in the payload")
  sim.advance(5 * 60)
  eq(sim.pubs(VALVE)[1].value, 1, "step 2 at 20 min from time zero")
end)

check("a mode that cannot be found: steps run, with a warning", function()
  local _, env, sim = load_app({ cfg = config({ active_modes = "away" }) })
  env.onStart()
  sim.value(COLD, 1)
  sim.advance(10 * 60 + 5)
  eq(#sim.to(1001), 1, "fail safe: the step runs")
  local warned = false
  for _, l in ipairs(sim.logs) do if l:find("no mode function", 1, true) then warned = true end end
  assert(warned, "warning")
end)

check("a key that is not one of the installation's modes is reported", function()
  local _, env, sim = load_app({ extra_functions = { S.MODE }, cfg = config({ active_modes = "armed" }) })
  env.onStart()
  local warned = false
  for _, l in ipairs(sim.logs) do if l:find("armed is not one of", 1, true) then warned = true end end
  assert(warned, "warning")
end)

check("the mode after a restart comes from IoT Open when the broker has none", function()
  local _, env, sim = load_app({ extra_functions = { S.MODE }, cfg = config({ active_modes = "away" }),
    status = { { topic = "obj/mode/default", value = 0 }, { topic = COLD, value = 1, timestamp = S.T0 - 12 * 60 } } })
  env.onStart()
  sim.advance(10)
  eq(#sim.notified, 0, "home: paused although 12 min have passed")
end)

-- ---- status and lifecycle -----------------------------------------------------------------------------------------

check("status: minutes and step per function, number of active", function()
  local _, env, sim = load_app({})
  env.onStart()
  sim.value(COLD, 1)
  sim.advance(12 * 60)
  local minutes = sim.pubs("obj/toolong/kitchen-water/101/minutes")
  eq(minutes[#minutes].value, 11, "minutes")
  eq(minutes[#minutes].msg, "step 1/2", "step")
  local active = sim.pubs("obj/toolong/kitchen-water/active")
  eq(active[#active].value, 1, "active")
end)

check("a function tagged later is picked up without losing running clocks", function()
  local functions = { water(101, COLD) }
  local _, env, sim = load_app({ functions = functions })
  env.onStart()
  sim.value(COLD, 1)
  sim.advance(5 * 60)
  sim.add_function(water(102, "obj/knx/0/1/11"))
  env.onFunctionsUpdated()
  assert(sim.handlers["obj/knx/0/1/11"], "new topic subscribed")
  sim.advance(5 * 60 + 5)
  eq(#sim.to(1001), 1, "the running clock was kept")
end)

check("no group set: the instance gets one of its own", function()
  local M = load_app({})
  eq(M.settings(config({ group = "" })).group, "toolong-5", "from the instance id")
  eq(M.settings(config({ group = "Kök vatten" })).group, "kok_vatten", "a name becomes a key")
end)

-- ---- the form and the metadata ----------------------------------------------------------------------------------

local function untagged(id, topic, name)
  return { id = id, installation_id = 1001, type = "boolean_text", meta = { name = name or "Diskmaskin", topic_read = topic, state_true = "1" } }
end

local function watch_config(rows, extra)
  local c = config(extra)
  c.watch = rows
  return c
end

check("the form tags the functions it lists, and the monitor watches them", function()
  local cfg = watch_config({ { watch_function = 102, watch_label = "diskmaskinen", watch_sound = "iotopen/dish.mp3" } })
  local _, env, sim = load_app({ cfg = cfg, functions = { untagged(102, "obj/knx/0/1/20") } })
  env.onStart()
  sim.advance(4)
  local meta = sim.fn(102).meta
  eq(meta["toolong.group"], "kitchen-water", "group")
  eq(meta["toolong.label"], "diskmaskinen", "label")
  eq(meta["toolong.sound"], "iotopen/dish.mp3", "sound")
  eq(meta.name, "Diskmaskin", "other keys kept")
  assert(sim.handlers["obj/knx/0/1/20"], "watched")
  eq(#sim.puts("/api/v2/edge/app/configured"), 0, "form already right: not written")
end)

check("a restart writes nothing when neither side changed", function()
  local cfg = watch_config({ { watch_function = 102, watch_label = "diskmaskinen" } })
  local _, env, sim = load_app({ cfg = cfg, functions = { untagged(102, "obj/knx/0/1/20") } })
  env.onStart()
  sim.advance(4)
  local _, env2, sim2 = load_app({ cfg = sim.instance_config, retained = sim.retained, clock = sim.clock + 60, functions = { sim.fn(102) } })
  env2.onStart()
  sim2.advance(4)
  eq(#sim2.puts("/api/v2/"), 0, "no writes")
end)

check("a row removed from the form removes only this instance's group", function()
  local fn = untagged(102, "obj/knx/0/1/20")
  local cfg = watch_config({ { watch_function = 102, watch_label = "diskmaskinen" } })
  local _, env, sim = load_app({ cfg = cfg, functions = { fn } })
  env.onStart()
  sim.advance(4)
  fn.meta["toolong.group"] = "kitchen-water,night" -- another instance watches it too
  local cfg2 = watch_config({})
  local _, env2, sim2 = load_app({ cfg = cfg2, retained = sim.retained, clock = sim.clock + 60, functions = { fn } })
  env2.onStart()
  sim2.advance(4)
  eq(fn.meta["toolong.group"], "night", "the other instance keeps it")
  eq(fn.meta["toolong.label"], "diskmaskinen", "label kept")
  eq(sim2.handlers["obj/knx/0/1/20"], nil, "no longer watched")
end)

check("a change in IoT Open updates the form, and a restart then changes nothing", function()
  local fn = untagged(102, "obj/knx/0/1/20")
  local cfg = watch_config({ { watch_function = 102, watch_label = "diskmaskinen" } })
  local _, env, sim = load_app({ cfg = cfg, functions = { fn } })
  env.onStart()
  sim.advance(4)
  fn.meta["toolong.label"] = "diskmaskinen i köket" -- changed in IoT Open's front end
  sim.add_function(water(103, "obj/knx/0/1/21"))       -- and a function tagged there
  env.onFunctionsUpdated()
  local w = sim.instance_config.watch
  eq(#w, 2, "both in the form")
  eq(w[1].watch_function, 102, "form order kept")
  eq(w[1].watch_label, "diskmaskinen i köket", "new label in the form")
  eq(w[2].watch_function, 103, "tagged function added")
  local _, env2, sim2 = load_app({ cfg = sim.instance_config, retained = sim.retained, clock = sim.clock + 60, functions = { fn, sim.fn(103) } })
  env2.onStart()
  sim2.advance(4)
  eq(#sim2.puts("/api/v2/"), 0, "no writes after the restart")
end)

check("whoever changed last wins, field by field", function()
  local fn = untagged(102, "obj/knx/0/1/20")
  local cfg = watch_config({ { watch_function = 102, watch_label = "diskmaskinen", watch_sound = "iotopen/a.mp3" } })
  local _, env, sim = load_app({ cfg = cfg, functions = { fn } })
  env.onStart()
  sim.advance(4)
  fn.meta["toolong.sound"] = "iotopen/b.mp3" -- changed elsewhere while the app was stopped
  local cfg2 = watch_config({ { watch_function = 102, watch_label = "disken", watch_sound = "iotopen/a.mp3" } })
  local _, env2, sim2 = load_app({ cfg = cfg2, retained = sim.retained, clock = sim.clock + 60, functions = { fn } })
  env2.onStart()
  sim2.advance(4)
  eq(fn.meta["toolong.label"], "disken", "the form changed the label")
  eq(fn.meta["toolong.sound"], "iotopen/b.mp3", "the sound changed elsewhere is kept")
  eq(sim2.instance_config.watch[1].watch_sound, "iotopen/b.mp3", "and the form shows it")
end)

check("an old instance with tags only gets its form filled in", function()
  local _, env, sim = load_app({})
  env.onStart()
  sim.advance(4)
  eq(sim.instance_config.watch[1].watch_function, 101, "tagged function in the form")
  eq(#sim.puts("/api/v2/functionx"), 0, "metadata untouched")
end)

check("when IoT Open refuses the form, the metadata still applies and a restart removes nothing", function()
  local _, env, sim = load_app({ config_refused = true })
  env.onStart()
  sim.advance(4)
  local warned = false
  for _, l in ipairs(sim.logs) do if l:find("could not be updated from the metadata", 1, true) then warned = true end end
  assert(warned, "warning")
  local _, env2, sim2 = load_app({ cfg = sim.instance_config, config_refused = true, retained = sim.retained, clock = sim.clock + 60 })
  env2.onStart()
  sim2.advance(4)
  eq(sim2.fn(101).meta["toolong.group"], "kitchen-water", "tag kept")
  eq(#sim2.puts("/api/v2/functionx"), 0, "nothing removed")
end)

check("a function in two instances is watched by both", function()
  local fn = water(101, COLD, { ["toolong.group"] = "night, kitchen-water" })
  local _, env, sim = load_app({ functions = { fn } })
  env.onStart()
  assert(sim.handlers[COLD], "kitchen-water")
  local _, env2, sim2 = load_app({ cfg = config({ group = "night" }), functions = { fn } })
  env2.onStart()
  assert(sim2.handlers[COLD], "night")
end)

-- ---- the advanced page and plain words ---------------------------------------------------------------------------

check("commands from the advanced page join the step at the same time, or become a step of their own", function()
  local M = load_app({})
  local s = M.settings(config({
    steps = { { step_after_min = 20, step_outputs = { 1 } } },
    controls = { { control_after_min = 20, control_topic = "set/obj/knx/0/1/40", control_value = "1", control_verify_topic = "obj/knx/0/2/40" },
                 { control_after_min = 30, control_topic = "set/obj/knx/0/1/41", control_value = "1" } },
  }))
  eq(#s.steps, 2, "steps")
  eq(s.steps[1].control.topic, "set/obj/knx/0/1/40", "joined")
  eq(s.steps[1].outputs[1], 1, "the step's notification kept")
  eq(s.steps[2].after_min, 30, "own step")
  eq(#s.steps[2].outputs, 0, "nothing else")
end)

check("modes and recipient groups can be written as people see them", function()
  local M, env, sim = load_app({ cfg = config({ active_modes = "Borta, Semester", steps = { { step_after_min = 1, step_outputs = { 1001 } } } }),
    extra_functions = { S.MODE } })
  env.onStart()
  eq(M.mode_labels(S.MODE.meta["mode.states"]).borta, "away", "label to key")
  eq(M.settings(config({ steps = { { step_after_min = 1, step_recipient_group = "Hemtjänst natt" } } })).steps[1].recipient_group, "hemtjanst_natt", "group key")
  sim.value("obj/mode/default", 1)
  sim.value(COLD, 1)
  sim.advance(70)
  eq(#sim.to(1001), 1, "runs in Borta")
  sim.value("obj/mode/default", 0)
  sim.value(COLD, 0)
  sim.advance(20)
  sim.value(COLD, 1)
  sim.advance(70)
  eq(#sim.to(1001), 1, "paused in Hemma")
end)

check("a step at 0 minutes runs at once", function()
  local _, env, sim = load_app({ cfg = config({ steps = { { step_after_min = 0, step_outputs = { 1001 } } } }) })
  env.onStart()
  sim.value(COLD, 1)
  sim.advance(5)
  eq(#sim.to(1001), 1, "at once")
end)

check("the code returns nothing in the edge client", function()
  local env = setmetatable({ cfg = {}, app = { id = 1 }, log = { i = print, e = print }, json = { null = {} } }, { __index = _G })
  local chunk = assert(loadfile("app.lua", "t", env))
  eq(select("#", chunk()), 0, "returned values")
end)

print(string.format("%d of %d passed", count - failures, count))
os.exit(failures == 0 and 0 or 1)
