-- The simulated edge client used by the tests and by tools/simulate.lua: cfg, app, log, json, lynx, mq, timer and
-- the clock. All names, addresses and numbers are made up.

local S = {}

-- ---- a tiny JSON for the simulation (the edge client has its own) ----------------------------------------------

S.json = { null = setmetatable({}, { __tostring = function() return "null" end }) }
function S.json:encode(v)
  local t = type(v)
  if t == "nil" or v == S.json.null then return "null" end
  if t == "boolean" or t == "number" then return tostring(v) end
  if t == "string" then return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"' end
  local keys, is_list = {}, (#v > 0)
  if is_list then
    local parts = {}
    for _, x in ipairs(v) do parts[#parts + 1] = S.json:encode(x) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, k in ipairs(keys) do parts[#parts + 1] = S.json:encode(tostring(k)) .. ":" .. S.json:encode(v[k]) end
  return "{" .. table.concat(parts, ",") .. "}"
end
function S.json:decode(s) -- enough for {"value":..,"timestamp":..,"msg":..}
  local out = {}
  for k, v in s:gmatch('"([%w_]+)"%s*:%s*("?[^,"}]*"?)') do
    if v:sub(1, 1) == '"' then out[k] = v:sub(2, -2) elseif v == "true" then out[k] = true elseif v == "false" then out[k] = false else out[k] = tonumber(v) end
  end
  return out
end

-- ---- the simulated edge client -------------------------------------------------------------------------------------

S.T0 = 1794300000

function S.water(id, topic, extra)
  local meta = { name = "Kök kallvatten", topic_read = topic, ["toolong.group"] = "kitchen-water", state_true = "1", state_false = "0" }
  for k, v in pairs(extra or {}) do meta[k] = v end
  return { id = id, type = "boolean_text", meta = meta }
end

S.SPEAKER = { id = 900, type = "audio", meta = { name = "Högtalare kök" } }
S.PLAY = { id = 901, type = "text", meta = { ["ha.part"] = "play", device_id = "900", topic_write = "set/obj/ha/media_player/speaker/play" } }
S.RECIPIENTS = { id = 950, type = "recipients", meta = { recipients_email_staff = "anna@example.com,bo@example.com", recipients_sms_staff = "+46700000001" } }

function S.config(extra)
  local c = {
    name = "Vatten i köket",
    group = "kitchen-water",
    debounce_s = 10,
    sound_default = "iotopen/kitchen-water-running.mp3",
    steps = {
      { step_after_min = 20, step_sound = true, step_outputs = { 1002, 1004 }, step_recipient_group = "staff",
        step_control_topic = "set/obj/knx/0/1/40", step_control_value = "1", step_verify_topic = "obj/knx/0/2/40", step_verify_s = 30 },
      { step_after_min = 10, step_sound = true, step_outputs = { 1001 }, step_recipient_group = "staff" },
    },
  }
  for k, v in pairs(extra or {}) do c[k] = v end
  return c
end

--- Loads app.lua in a simulated edge client. opts: cfg, functions, devices, status (lynx.getStatus answer),
--- notify_fails (function returning true while notifications fail).
function S.load_app(opts)
  local sim = { retained = opts.retained or {}, clock = opts.clock or S.T0, timers = {}, published = {}, notified = {}, logs = {}, handlers = {}, subs = {} }
  local functions = opts.functions or { S.water(101, "obj/knx/0/1/10") }
  local all_functions = { S.PLAY }
  for _, f in ipairs(opts.extra_functions or {}) do all_functions[#all_functions + 1] = f end
  for _, f in ipairs(functions) do all_functions[#all_functions + 1] = f end
  local function match(item, filter)
    for k, v in pairs(filter or {}) do
      if k == "type" then if item.type ~= v then return false end
      elseif (item.meta or {})[k] ~= v then return false end
    end
    return true
  end
  local lynx = {
    getFunctions = function(filter)
      local out = {}
      for _, f in ipairs(all_functions) do if match(f, filter) then out[#out + 1] = f end end
      return out
    end,
    getDevices = function(filter)
      local out = {}
      for _, d in ipairs(opts.devices or { S.SPEAKER, S.RECIPIENTS }) do if match(d, filter) then out[#out + 1] = d end end
      return out
    end,
    getStatus = function()
      if opts.offline then error("no connection") end
      if opts.status then return opts.status end
      return {}
    end,
    notify = function(id, body)
      if opts.notify_fails and opts.notify_fails(sim) then error("no connection") end
      sim.notified[#sim.notified + 1] = { id = id, body = body, at = sim.clock }
    end,
  }
  local mq = {}
  function mq:sub(topic) sim.subs[topic] = true end
  function mq:bind(topic, fn)
    sim.handlers[topic] = fn
    if sim.retained[topic] then fn(topic, sim.retained[topic]) end -- the broker sends a retained message at once
  end
  function mq:unbind(topic) sim.handlers[topic] = nil end
  function mq:pub(topic, payload, retain)
    sim.published[#sim.published + 1] = { topic = topic, payload = payload, at = sim.clock }
    if retain then sim.retained[topic] = payload end
  end
  local timer = {}
  function timer:after(secs, fn)
    local t = { at = sim.clock + secs, fn = fn }
    sim.timers[#sim.timers + 1] = t
    return { cancel = function() t.fn = nil end }
  end
  local function logger(level) return function(f, ...) sim.logs[#sim.logs + 1] = level .. " " .. string.format(f, ...) end end
  local os_fake = setmetatable({ time = function() return sim.clock end }, { __index = os })
  local env = setmetatable({
    TOOLONG_TEST = true,
    cfg = opts.cfg or S.config(),
    app = { id = 5, installation_id = 1001, name = "För länge" },
    json = S.json, lynx = lynx, mq = mq, timer = timer, os = os_fake,
    log = { i = logger("I"), w = logger("W"), e = logger("E"), d = logger("D") },
  }, { __index = _G })
  local M = assert(loadfile(S.root .. "app.lua", "t", env))()

  --- Runs the clock forward, firing timers in order.
  function sim.advance(secs)
    local target = sim.clock + secs
    while true do
      table.sort(sim.timers, function(a, b) return a.at < b.at end)
      local nxt = sim.timers[1]
      if not nxt or nxt.at > target then break end
      table.remove(sim.timers, 1)
      sim.clock = nxt.at
      if nxt.fn then nxt.fn() end
    end
    sim.clock = target
  end
  --- A value arrives on the local broker.
  function sim.value(topic, value)
    local h = sim.handlers[topic]
    assert(h, "not subscribed to " .. topic)
    h(topic, S.json:encode({ value = value, timestamp = sim.clock }))
  end
  function sim.pubs(topic)
    local out = {}
    for _, p in ipairs(sim.published) do if p.topic == topic then out[#out + 1] = S.json:decode(p.payload) end end
    return out
  end
  function sim.to(output)
    local out = {}
    for _, n in ipairs(sim.notified) do if n.id == output then out[#out + 1] = n end end
    return out
  end
  return M, env, sim
end

S.MODE = { id = 950, type = "mode", meta = { name = "Läge", topic_read = "obj/mode/default", topic_write = "set/obj/mode/default", ["mode.name"] = "default", ["mode.states"] = "0:home:Hemma,1:away:Borta,2:vacation:Semester" } }
S.COLD = "obj/knx/0/1/10"
S.PLAYER = "set/obj/ha/media_player/speaker/play"
S.VALVE = "set/obj/knx/0/1/40"


S.root = ""
return S
