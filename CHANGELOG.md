# Changelog

## Unreleased

## 0.3.1

- Warnings (a notification output that fails, a command that is not confirmed, no mode function, latest values
  that cannot be read) stopped the app: the edge client's log has no `log.w`. They are now written with `log.i` as
  `warning: ...`, and the tests use a log without `w`.

## 0.3.0

- A restart of the edge client no longer makes the instances silent until the next value: each clock is saved
  retained on the local broker (`obj/toolong/<group>/<function id>/clock`) with the steps that have run, and
  restored at start, also without internet. With internet, IoT Open's latest values still win, so a function that
  became inactive during the restart is reset. Steps that had run are not repeated.

## 0.2.0

- System modes: `active_modes` (keys, e.g. `away, vacation`) limits an instance to some of the installation's modes
  from the [Mode](https://github.com/automateit-se/edge-app-mode) app. In other modes the steps wait while the clock
  goes on. Without a mode function the steps always run, with a warning. The payload has `mode`.

## 0.1.0

- First version. One instance watches every function with metadata `toolong.group`, each with a clock of its own
  from time zero. Steps at minutes from start, each with any of: a command with a check that it took effect, a sound
  on the installation's speaker (device of type `audio`), and one or more notification outputs in parallel.
- Payload for the outputs: `label`, `minutes`, `step`, `active` and more, plus `recipients_email` / `recipients_sms`
  for the step's group from the [Recipients](https://github.com/automateit-se/edge-app-recipients) app.
- Repeats of sound and notification, never of commands. A short return (debounce) does not reset the clock.
- After a restart the clocks go on from the values' own timestamps. Notifications that fail are queued and sent
  later, marked `late` after an hour.
- Status on `obj/toolong/<group>/<function id>/minutes` and `obj/toolong/<group>/active`.
- Not yet: system modes (home / away) and an acknowledge button.
