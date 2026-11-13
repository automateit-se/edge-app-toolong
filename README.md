# Too long - För länge (IoT Open edge app)

An IoT Open edge app that warns when something has been active too long - water running, a fridge door open, the
oven on - and acts on it in steps: a sound on the speaker, notifications by e-mail or SMS, and a command such as
closing the water valve.

Technical names (metadata keys, payload, topics) are in English; the settings form is in Swedish.

## The idea

- **One instance = one monitoring policy**, set in a form with two pages: *Bevakning* (what is watched, the steps,
  the modes) for everyone, and *Avancerat* (commands, sound, technical settings) for the installer.
- **Every function has a clock of its own**, starting at time zero when it becomes active.
- **Every step's time counts from time zero**, never from the step before. "20 minutes" always means 20 minutes
  after the water started running. 0 means at once.
- Texts and recipients live in IoT Open's notification outputs; the app sends a payload the template uses.

## The form and the metadata

What is watched is stored as metadata on the functions in IoT Open, and the form is a way to edit it:

| Metadata on the function | In the form (*Det här bevakas*) |
|---|---|
| `toolong.group` | the row exists (the instance's group; a comma separated list when several instances watch it) |
| `toolong.label` | Namn i aviseringen, e.g. `kylskåpsdörren` |
| `toolong.sound` | Eget ljud |
| `toolong.active_value` | Värde som betyder aktiv |

The two are kept in step, and **whoever changed last wins**, field by field:

- **The form changed** (IoT Open restarts the app with the new config): the fields that changed since the form the
  app last applied are written to the functions. A row removed from the form removes only this instance's group
  from the function. Other keys on the function, and changes made elsewhere in other fields, are kept.
- **The metadata changed** (in IoT Open's front end or a third system; `onFunctionsUpdated`): the form is written
  again from the metadata (`PUT /api/v2/edge/app/configured/<installation>/<instance>`), so every front end shows
  what applies. The edge client then restarts the app, which changes nothing more.
- The form the app last applied is kept retained on the local broker (`obj/toolong/<group>/form`), so a restart is
  not taken for a change. Without it (a new broker) the form is added to the metadata and nothing is removed.
- If IoT Open refuses to update the form, a warning is logged; the metadata still applies and the form shows an
  older list until it is saved again.
- An instance from before 0.4 (tags only) gets its form filled in from the metadata at the first start.

## Settings

*Bevakning*:

| Setting | Key | Meaning |
|---|---|---|
| Namn | `name` | sent in the payload as `instance` |
| Det här bevakas | `watch` | rows of `watch_function`, `watch_label`, `watch_sound`, `watch_active_value` (see above) |
| Steg | `steps` | one row per step, see below |
| Gäller i lägena | `active_modes` | modes as people see them (`Borta, Semester`) or their keys (`away, vacation`); empty = always |

A step:

| Setting | Key | Meaning |
|---|---|---|
| Efter (minuter) | `step_after_min` | minutes from time zero, 0 = at once |
| Aviseringar | `step_outputs` | notification outputs, called in parallel; e-mail first, SMS when urgent |
| Till vilka | `step_recipient_group` | group from the Recipients app, as written there (`Hemtjänst natt` = `hemtjanst_natt`) |
| Spela ljud | `step_sound` | play the function's sound on the speaker |
| Upprepa var (minuter) / Högst antal | `step_repeat_every_min`, `step_max_repeats` | repeat sound and notification, never a command |

*Avancerat*:

| Setting | Key | Meaning |
|---|---|---|
| Styrningar | `controls` | rows of `control_after_min`, `control_topic`, `control_value`, `control_verify_topic`, `control_verify_s`: a command sent once, e.g. `set/obj/knx/0/1/40` = `1`; a step at the same time waits until the check topic shows the value |
| Standardljud | `sound_default` | sound file when the function has no sound of its own |
| Högtalare | `player_device` | only when there are several speakers (devices of type `audio`) |
| Gruppnamn | `group` | the link to the functions; empty = `toolong-<instance id>` |
| Värde som betyder aktiv (alla) | `active_value` | empty: the function's `state_open` / `state_on` / `state_true`, otherwise `1` |
| Avstudsning (sekunder) | `debounce_s` | a shorter return to inactive does not reset the clock (default 10) |
| Vilket läge | `mode_name` | only with several modes, default `default` |

Commands in a step (`step_control_topic` and so on, before 0.4) still work.

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
queue, speaker and recipients, and the form and the metadata kept in step both ways. All names, addresses and numbers in the tests are made up.

## License

MIT
