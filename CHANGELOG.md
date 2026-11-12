# Changelog

## Unreleased

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
