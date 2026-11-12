# Too long - För länge (IoT Open edge app)

An IoT Open edge app that warns when something has been active too long - water running, a fridge door open, the
oven on - and acts on it in steps: a sound on the speaker, notifications by e-mail or SMS, and a command such as
closing the water valve.

Technical names (metadata keys, payload, topics) are in English; the settings form is in Swedish.

## The idea

- **One instance = one monitoring policy.** It watches every function with metadata `toolong.group` equal to the
  instance's group. A new sensor is added by tagging it; the app does not change.
- **Every function has a clock of its own**, starting at time zero when it becomes active.
- **Every step's time counts from time zero**, never from the step before. "20 minutes" always means 20 minutes
  after the water started running.
- What differs between the functions lives on the function: `toolong.label` (the name in texts, e.g.
  `kylskåpsdörren`), `toolong.sound` (its own sound file), `toolong.active_value`.
- Texts and recipients live in IoT Open's notification outputs; the app sends a payload the template uses.

## Settings

| Setting | Key | Meaning |
|---|---|---|
| Namn | `name` | sent in the payload as `instance` |
| Grupp (tagg) | `group` | functions with `toolong.group` = this are watched |
| Värde som betyder aktiv | `active_value` | empty: the function's `state_open` / `state_on` / `state_true`, otherwise `1` |
| Avstudsning (sekunder) | `debounce_s` | a shorter return to inactive does not reset the clock (default 10) |
| Gäller i lägena | `active_modes` | keys of the installation's modes, e.g. `away, vacation`; empty = always |
| Vilket läge | `mode_name` | only with several modes, default `default` |
| Steg | `steps` | one row per step, see below |
| Standardljud | `sound_default` | sound file when the function has no `toolong.sound` |
| Högtalare | `player_device` | only when there are several speakers (devices of type `audio`) |

A step:

| Setting | Key | Meaning |
|---|---|---|
| Efter (minuter från start) | `step_after_min` | minutes from time zero |
| Spela ljud | `step_sound` | play the function's sound on the speaker |
| Aviseringar | `step_outputs` | notification outputs, called in parallel; e-mail first, SMS when urgent |
| Mottagargrupp | `step_recipient_group` | group from the Recipients app, e.g. `staff` |
| Styrning: topic / värde | `step_control_topic`, `step_control_value` | a command sent once, e.g. `set/obj/knx/0/1/40` = `1` |
| Styrning: kontroll mot | `step_verify_topic`, `step_verify_s` | the step's sound and notification wait until this topic shows the value, at most `step_verify_s` |
| Upprepa var (minuter) / Högst antal | `step_repeat_every_min`, `step_max_repeats` | repeat sound and notification, never the command |

## Payload

| Field | Example |
|---|---|
| `label` | `kylskåpsdörren` (`toolong.label`, otherwise the function's name) |
| `function_id`, `instance`, `group` | `784102`, `Kyl och frys`, `fridge-freezer` |
| `step`, `steps` | `2`, `2` |
| `minutes`, `seconds`, `since` | minutes and seconds since time zero, time zero as UNIX time |
| `repeat` | 0 the first time, then 1, 2 ... |
| `control` | `{"topic":"set/obj/knx/0/1/40","value":1,"confirmed":true}` on steps with a command |
| `active`, `active_count` | every active function of the instance: `[{"label":...,"minutes":...}]` |
| `recipients_email`, `recipients_sms` | the step's group from the Recipients app |
| `late` | `true` when the notification waited more than an hour (no internet) |
| `mode` | the installation's mode key when the step ran, e.g. `away` |

Template examples:

```
{{.installation.Name}}: {{.payload.label}} har varit öppen i {{.payload.minutes}} min.
```

and as the recipient of an e-mail output: `{{.payload.recipients_email}}`.

## Sound

Sounds are played only when the installation has a device of type `audio` (ha-iotopen 0.9.0 gives a mirrored
speaker with *Play* that type). The app sends the file name to that device's function with `ha.part = play`.
Without a speaker, sounds are skipped and logged once; notifications and commands go on as usual.

## Behaviour

- **Commands** are sent once per episode and never undone: the app does not open the valve again.
- **Restart**: each clock is saved retained on the edge client's local broker
  (`obj/toolong/<group>/<function id>/clock`: value = time zero, `msg` = the steps that have run), so a restart
  goes on where it was, also without internet and although sensors such as KNX do not resend their values. With
  internet, the latest values in IoT Open (`lynx.getStatus`) are read too: a function that became inactive during
  the restart is reset. Steps passed during the restart run once and steps that had run are not repeated; a sound
  more than an hour late is skipped, a command is still sent.
- **No internet**: sounds and commands work locally. Notifications that fail are queued and retried every minute,
  and marked `late` after an hour.
- **Status**: `obj/toolong/<group>/<function id>/minutes` (minutes, `msg` = `step n/m`) and
  `obj/toolong/<group>/active` (number active, `msg` = their labels), every minute.

## Modes

With `active_modes`, an instance applies only in some of the installation's modes (the
[Mode](https://github.com/automateit-se/edge-app-mode) app, a function of type `mode`): for example door alarms only
`away` and `vacation`. In other modes no step runs, but the clock goes on, so a change of mode in the middle of an
episode takes it from the right time: the door that has been open 15 minutes when the mode becomes `away` gets its
10-minute step at once. If the mode function cannot be found or has no value yet, the steps run (better a warning
too many), and a warning is logged.

Planned: an acknowledge button.

## Tests

```bash
lua5.3 tests/test_app.lua
```

The tests run `app.lua` in a simulated edge client with a simulated clock, so a whole timeline runs in
milliseconds: steps from time zero, the valve and its check, debounce, two clocks, repeats, restart, offline
queue, speaker and recipients. All names, addresses and numbers in the tests are made up.

## License

MIT
