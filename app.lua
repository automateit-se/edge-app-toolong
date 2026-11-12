-- Too long (För länge): warns when something has been active too long, for example water running, a fridge door
-- open or the oven on, and acts on it in steps.
--
-- One app instance is one monitoring policy. It watches every function with metadata toolong.group equal to the
-- instance's group, each with a clock of its own that starts at time zero, when the function became active. Every
-- step's time counts from time zero, never from the step before. A step can
--   - send a command (for example close the water valve) and check that it took effect,
--   - play a sound on the installation's speaker (a device of type "audio", see ha-iotopen 0.9.0),
--   - call one or more IoT Open notification outputs (e-mail first, SMS for what is urgent) with a payload that
--     the output's template uses: {{.payload.label}}, {{.payload.minutes}}, {{.payload.recipients_email}} ...
-- When the function has been back to inactive for debounce_s seconds, the clock is reset. Commands are never
-- repeated and never undone by the app.
--
-- Version 0.1: no system modes and no acknowledge button yet (planned for 0.2). Sounds go straight to the speaker.

local VERSION = "0.1.0"
local TICK_S = 5
local LATE_S = 3600 -- a notification queued longer than this is marked late; a missed sound this old is skipped
local RETRY_S = 60

local M = {}

-- ---- small helpers -----------------------------------------------------------------------------------------------

local function is_null(v) return v == nil or (json ~= nil and v == json.null) end
local function num(v, d) local n = tonumber(v) if n == nil or n ~= n then return d end return n end
local function bool(v, d)
  if is_null(v) or v == "" then return d end
  return v == true or v == "true" or v == 1 or v == "1"
end
local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function str(v) if is_null(v) then return "" end return trim(v) end

--- The first argument that is set and not blank, trimmed (nil arguments allowed, unlike ipairs over a list).
local function first_set(...)
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if not is_null(v) and trim(v) ~= "" then return trim(v) end
  end
  return nil
end

--- "1", 1 and 1.0 are the same value; text is compared as text.
function M.same_value(a, b)
  if is_null(a) or is_null(b) then return false end
  local na, nb = tonumber(a), tonumber(b)
  if na ~= nil and nb ~= nil then return na == nb end
  return tostring(a) == tostring(b)
end

local function ids(v)
  local out = {}
  if type(v) == "table" then
    for k, x in pairs(v) do
      local id = math.type and math.type(k) == "integer" and tonumber(x) or tonumber(k) or tonumber(x)
      if id then out[#out + 1] = math.floor(id) end
    end
  elseif tonumber(v) then
    out[1] = math.floor(tonumber(v))
  end
  table.sort(out)
  return out
end

-- ---- settings ------------------------------------------------------------------------------------------------------

--- The instance's settings from the app's configuration, checked. Steps are sorted by time; a step without a
--- positive time is left out.
function M.settings(c)
  c = c or {}
  local s = {
    name = str(c.name) ~= "" and str(c.name) or "För länge",
    group = str(c.group):lower(),
    active_value = str(c.active_value),
    debounce_s = math.max(0, num(c.debounce_s, 10)),
    sound_default = str(c.sound_default),
    player_device = tonumber(c.player_device) and math.floor(tonumber(c.player_device)) or nil,
    steps = {},
  }
  for _, st in ipairs(type(c.steps) == "table" and c.steps or {}) do
    if type(st) == "table" then
      local after = num(st.step_after_min, 0)
      if after > 0 then
        local step = {
          after_s = after * 60,
          after_min = after,
          sound = bool(st.step_sound, false),
          outputs = ids(st.step_outputs),
          recipient_group = str(st.step_recipient_group):lower(),
          repeat_s = math.max(0, num(st.step_repeat_every_min, 0)) * 60,
          max_repeats = math.max(0, math.floor(num(st.step_max_repeats, 0))),
        }
        local topic = str(st.step_control_topic)
        if topic ~= "" then
          step.control = {
            topic = topic,
            value = tonumber(st.step_control_value) or str(st.step_control_value),
            verify_topic = str(st.step_verify_topic) ~= "" and str(st.step_verify_topic) or nil,
            verify_s = math.max(1, num(st.step_verify_s, 30)),
          }
        end
        s.steps[#s.steps + 1] = step
      end
    end
  end
  table.sort(s.steps, function(a, b) return a.after_s < b.after_s end)
  for i, st in ipairs(s.steps) do st.n = i end
  return s
end

--- The value that means active for a function: its own toolong.active_value, the instance's, the function's
--- state_open / state_on / state_true, or 1.
function M.active_value(fn, settings)
  local meta = fn.meta or {}
  return first_set(meta["toolong.active_value"], settings.active_value, meta.state_open, meta.state_on, meta.state_true) or "1"
end

function M.label(fn)
  local meta = fn.meta or {}
  return first_set(meta["toolong.label"], meta.name) or ("funktion " .. tostring(fn.id))
end

-- ---- the monitor: pure logic, driven by values and a clock --------------------------------------------------------
-- A monitor holds one track per watched function and returns the actions to take; the edge client glue below
-- carries them out. Nothing here reads the clock or talks to IoT Open, so the tests can drive it.

local Monitor = {}
Monitor.__index = Monitor

function M.monitor(settings, functions)
  local self = setmetatable({ settings = settings, tracks = {}, by_topic = {} }, Monitor)
  self:set_functions(functions or {})
  return self
end

--- Replaces the watched functions; tracks of functions that stay are kept, so a running clock goes on.
function Monitor:set_functions(functions)
  local tracks, by_topic = {}, {}
  for _, fn in ipairs(functions) do
    local topic = fn.meta and fn.meta.topic_read
    if topic and topic ~= "" then
      local t = self.tracks[fn.id] or { fired = {}, repeats = {}, next_repeat = {} }
      t.fn, t.label, t.active_value, t.topic = fn, M.label(fn), M.active_value(fn, self.settings), topic
      tracks[fn.id] = t
      by_topic[topic] = by_topic[topic] or {}
      table.insert(by_topic[topic], fn.id)
    end
  end
  self.tracks, self.by_topic = tracks, by_topic
end

function Monitor:topics()
  local out = {}
  for topic in pairs(self.by_topic) do out[#out + 1] = topic end
  table.sort(out)
  return out
end

local function reset(t)
  t.since, t.inactive_since = nil, nil
  t.fired, t.repeats, t.next_repeat = {}, {}, {}
end

--- A value arrived on a watched topic (ts = the value's own timestamp). Returns the ids whose status changed.
function Monitor:value(topic, value, ts, now)
  local changed = {}
  for _, id in ipairs(self.by_topic[topic] or {}) do
    local t = self.tracks[id]
    if M.same_value(value, t.active_value) then
      if t.since == nil then
        t.since = math.min(ts or now, now)
        changed[#changed + 1] = id
      end
      t.inactive_since = nil
    elseif t.since ~= nil and t.inactive_since == nil then
      t.inactive_since = ts or now
    end
  end
  return changed
end

function Monitor:active_list(now)
  local out = {}
  for id, t in pairs(self.tracks) do
    if t.since then out[#out + 1] = { label = t.label, minutes = math.floor((now - t.since) / 60), function_id = id } end
  end
  table.sort(out, function(a, b) return a.minutes > b.minutes or (a.minutes == b.minutes and a.label < b.label) end)
  return out
end

--- The payload for a notification about track t at step st.
function Monitor:payload(id, t, st, now, rep)
  local active = self:active_list(now)
  local list = {}
  for _, a in ipairs(active) do list[#list + 1] = { label = a.label, minutes = a.minutes } end
  return {
    label = t.label,
    function_id = id,
    instance = self.settings.name,
    group = self.settings.group,
    step = st.n,
    steps = #self.settings.steps,
    minutes = math.floor((now - t.since) / 60),
    seconds = math.floor(now - t.since),
    since = math.floor(t.since),
    ["repeat"] = rep or 0,
    active = list,
    active_count = #list,
  }
end

--- Moves every clock forward to now. Returns the actions: { kind = "reset" | "step" | "repeat", id, step, ... }.
function Monitor:tick(now)
  local actions = {}
  local ids_sorted = {}
  for id in pairs(self.tracks) do ids_sorted[#ids_sorted + 1] = id end
  table.sort(ids_sorted)
  for _, id in ipairs(ids_sorted) do
    local t = self.tracks[id]
    if t.since and t.inactive_since and now - t.inactive_since >= self.settings.debounce_s then
      reset(t)
      actions[#actions + 1] = { kind = "reset", id = id, label = t.label }
    elseif t.since then
      local elapsed = now - t.since
      for _, st in ipairs(self.settings.steps) do
        if not t.fired[st.n] and elapsed >= st.after_s then
          t.fired[st.n] = true
          if st.repeat_s > 0 then t.next_repeat[st.n] = t.since + st.after_s + st.repeat_s end
          actions[#actions + 1] = {
            kind = "step", id = id, step = st, label = t.label, fn = t.fn,
            -- passed while the app was not running: the command is still sent, an old sound is skipped
            missed_s = elapsed - st.after_s,
            payload = self:payload(id, t, st, now, 0),
          }
        elseif t.fired[st.n] and st.repeat_s > 0 and t.next_repeat[st.n] and now >= t.next_repeat[st.n]
          and (st.max_repeats == 0 or (t.repeats[st.n] or 0) < st.max_repeats) then
          t.repeats[st.n] = (t.repeats[st.n] or 0) + 1
          t.next_repeat[st.n] = t.next_repeat[st.n] + st.repeat_s
          while t.next_repeat[st.n] <= now do t.next_repeat[st.n] = t.next_repeat[st.n] + st.repeat_s end
          actions[#actions + 1] = {
            kind = "repeat", id = id, step = st, label = t.label, fn = t.fn, missed_s = 0,
            payload = self:payload(id, t, st, now, t.repeats[st.n]),
          }
        end
      end
    end
  end
  return actions
end

--- Status per watched function: minutes since time zero (0 when inactive) and "step n/m".
function Monitor:status(now)
  local out = {}
  for id, t in pairs(self.tracks) do
    local minutes, msg = 0, ""
    if t.since then
      minutes = math.floor((now - t.since) / 60)
      local done = 0
      for _, st in ipairs(self.settings.steps) do if t.fired[st.n] then done = st.n end end
      msg = string.format("step %d/%d", done, #self.settings.steps)
    end
    out[#out + 1] = { id = id, minutes = minutes, msg = msg }
  end
  table.sort(out, function(a, b) return a.id < b.id end)
  return out
end

M.Monitor = Monitor

-- ---- recipients and speakers -----------------------------------------------------------------------------------

--- recipients_email and recipients_sms for a group, from every device of type "recipients" (the Recipients app).
function M.recipients(devices, group)
  if group == nil or group == "" then return {} end
  local out = {}
  for _, channel in ipairs({ "email", "sms" }) do
    local seen, list = {}, {}
    for _, d in ipairs(devices or {}) do
      local v = d.type == "recipients" and d.meta and d.meta["recipients_" .. channel .. "_" .. group]
      if type(v) == "string" then
        for x in v:gmatch("[^,]+") do
          x = trim(x)
          if x ~= "" and not seen[x] then seen[x] = true list[#list + 1] = x end
        end
      end
    end
    if #list > 0 then table.sort(list) out["recipients_" .. channel] = table.concat(list, ",") end
  end
  return out
end

--- The topic_write of the speaker's Play function: a device of type "audio" (the chosen one, or the first) and its
--- function with ha.part = play. nil when the installation has no speaker.
function M.player_topic(devices, functions, wanted_device)
  local audio = {}
  local first
  for _, d in ipairs(devices or {}) do
    if d.type == "audio" then
      audio[d.id] = true
      if first == nil or d.id < first then first = d.id end
    end
  end
  local dev = wanted_device and audio[wanted_device] and wanted_device or first
  if dev == nil then return nil end
  for _, fn in ipairs(functions or {}) do
    local meta = fn.meta or {}
    if meta["ha.part"] == "play" and tonumber(meta.device_id) == dev and meta.topic_write and meta.topic_write ~= "" then
      return meta.topic_write
    end
  end
  return nil
end

-- ---- edge client glue ----------------------------------------------------------------------------------------------

local state = { monitor = nil, settings = nil, devices = {}, player = nil, verify = {}, queue = {}, warned = {} }

local function now() return os.time() end

local function warn_once(key, f, ...)
  if state.warned[key] then return end
  state.warned[key] = true
  log.w(f, ...)
end

local function publish(topic, value, msg)
  mq:pub(topic, json:encode({ value = value, msg = msg or "", timestamp = now() }), false, 1)
end

local function status_base() return "obj/toolong/" .. state.settings.group end

local function publish_status()
  local t = now()
  for _, s in ipairs(state.monitor:status(t)) do
    publish(status_base() .. "/" .. tostring(s.id) .. "/minutes", s.minutes, s.msg)
  end
  local active = state.monitor:active_list(t)
  local labels = {}
  for _, a in ipairs(active) do labels[#labels + 1] = a.label end
  publish(status_base() .. "/active", #active, table.concat(labels, ", "))
end

local function send(output, payload, queued_at)
  local body = payload
  if queued_at and now() - queued_at > LATE_S then
    body = {}
    for k, v in pairs(payload) do body[k] = v end
    body.late = true
  end
  local ok, err = pcall(lynx.notify, output, body)
  if not ok then
    state.queue[#state.queue + 1] = { output = output, payload = payload, at = queued_at or now() }
    log.w("notification output %d could not be called, queued: %s", output, tostring(err))
  end
  return ok
end

local function retry_queue()
  local q = state.queue
  state.queue = {}
  for _, item in ipairs(q) do send(item.output, item.payload, item.at) end
end

local function notify(st, payload)
  if #st.outputs == 0 then return end
  local full = {}
  for k, v in pairs(payload) do full[k] = v end
  for k, v in pairs(M.recipients(state.devices, st.recipient_group)) do full[k] = v end
  for _, output in ipairs(st.outputs) do send(output, full) end
end

local function play(a)
  if not a.step.sound then return end
  if a.missed_s > LATE_S then
    log.i("%s: sound for step %d skipped, it is %d minutes late", a.label, a.step.n, math.floor(a.missed_s / 60))
    return
  end
  if state.player == nil then
    warn_once("no_player", "no speaker (device of type audio with a Play function): sounds are skipped")
    return
  end
  local meta = a.fn.meta or {}
  local file = first_set(meta["toolong.sound"], state.settings.sound_default)
  if file == nil then
    warn_once("no_sound_" .. tostring(a.id), "%s has no toolong.sound and the instance no default sound", a.label)
    return
  end
  publish(state.player, file)
end

local function run(a)
  if a.kind == "reset" then
    log.i("%s: back to normal, clock reset", a.label)
    return
  end
  local st = a.step
  if a.kind == "step" and st.control then
    publish(st.control.topic, st.control.value)
    log.i("%s: step %d, sent %s to %s", a.label, st.n, tostring(st.control.value), st.control.topic)
    if st.control.verify_topic then
      -- the step's sound and notification wait for the check, so the text can say whether it worked
      state.verify[#state.verify + 1] = { action = a, deadline = now() + st.control.verify_s }
      return
    end
    a.payload.control = { topic = st.control.topic, value = st.control.value }
  end
  play(a)
  notify(st, a.payload)
  log.i("%s: step %d%s", a.label, st.n, a.kind == "repeat" and (" repeat " .. a.payload["repeat"]) or "")
end

local last_values = {}

local function check_verifications(force)
  local keep = {}
  for _, v in ipairs(state.verify) do
    local c = v.action.step.control
    local ok = M.same_value(last_values[c.verify_topic], c.value)
    if ok or force or now() >= v.deadline then
      v.action.payload.control = { topic = c.topic, value = c.value, confirmed = ok }
      if not ok then log.w("%s: %s did not confirm %s", v.action.label, c.verify_topic, tostring(c.value)) end
      play(v.action)
      notify(v.action.step, v.action.payload)
    else
      keep[#keep + 1] = v
    end
  end
  state.verify = keep
end

local function on_message(topic, payload)
  local ok, data = pcall(json.decode, json, payload)
  if not ok or type(data) ~= "table" then return end
  last_values[topic] = data.value
  if state.monitor and state.monitor.by_topic[topic] then
    local changed = state.monitor:value(topic, data.value, tonumber(data.timestamp), now())
    for _, id in ipairs(changed) do log.i("%s: active, clock started", state.monitor.tracks[id].label) end
  end
  check_verifications(false)
end

local subscribed = {}

local function subscribe(topics)
  for topic in pairs(subscribed) do
    mq:unbind(topic, on_message)
  end
  subscribed = {}
  for _, topic in ipairs(topics) do
    if not subscribed[topic] then
      subscribed[topic] = true
      mq:sub(topic, 1)
      mq:bind(topic, on_message)
    end
  end
end

local function verify_topics()
  local out = {}
  for _, st in ipairs(state.settings.steps) do
    if st.control and st.control.verify_topic then out[#out + 1] = st.control.verify_topic end
  end
  return out
end

--- Reads the watched functions, devices and the speaker again; keeps running clocks.
local function refresh()
  local functions = lynx.getFunctions({ ["toolong.group"] = state.settings.group }) or {}
  local mine = {}
  for _, fn in ipairs(functions) do
    if fn.meta and fn.meta["toolong.group"] == state.settings.group then mine[#mine + 1] = fn end
  end
  state.monitor:set_functions(mine)
  state.devices = lynx.getDevices() or {}
  state.player = M.player_topic(state.devices, lynx.getFunctions({ ["ha.part"] = "play" }) or {}, state.settings.player_device)
  local topics = state.monitor:topics()
  for _, t in ipairs(verify_topics()) do topics[#topics + 1] = t end
  subscribe(topics)
  return #mine
end

--- At start: the latest value of every watched function from IoT Open, so a clock that ran before a restart goes
--- on from the value's own timestamp. Without internet the clocks start with the next value instead.
local function catch_up()
  local topics = state.monitor:topics()
  if #topics == 0 then return end
  local ok, statuses = pcall(lynx.getStatus, topics)
  if not ok or type(statuses) ~= "table" then
    log.w("latest values could not be read, clocks start with the next value")
    return
  end
  for _, s in ipairs(statuses) do
    if type(s) == "table" and s.topic then
      local topic = tostring(s.topic):gsub("^%d+/", "")
      state.monitor:value(topic, s.value, tonumber(s.timestamp), now())
    end
  end
end

local function tick()
  timer:after(TICK_S, tick)
  local ok, err = pcall(function()
    for _, a in ipairs(state.monitor:tick(now())) do run(a) end
    check_verifications(false)
  end)
  if not ok then log.e("tick: %s", tostring(err)) end
end

local function every_minute()
  timer:after(60, every_minute)
  pcall(publish_status)
  if #state.queue > 0 then pcall(retry_queue) end
end

function onStart()
  state.settings = M.settings(cfg)
  if state.settings.group == "" then
    log.e("no group set: nothing to watch")
    return
  end
  if #state.settings.steps == 0 then log.w("no steps with a time: the app only shows status") end
  state.monitor = M.monitor(state.settings, {})
  local ok, n = pcall(refresh)
  if not ok then log.e("could not read functions: %s", tostring(n)) n = 0 end
  pcall(catch_up)
  log.i("toolong %s: %s watches %d functions with toolong.group = %s, %d steps", VERSION, state.settings.name, n,
    state.settings.group, #state.settings.steps)
  timer:after(TICK_S, tick)
  timer:after(1, every_minute)
end

function onFunctionsUpdated()
  if state.monitor then
    local ok, err = pcall(refresh)
    if not ok then log.e("could not read functions: %s", tostring(err)) end
  end
end

function onDevicesUpdated() onFunctionsUpdated() end

function onExit() end

-- iotopen-rt treats anything the app's code returns as an error, so the functions are only handed out to the tests
if TOOLONG_TEST then
  M._state = state
  return M
end
