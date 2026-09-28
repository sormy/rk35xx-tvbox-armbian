# Remote keymaps need a correctness pass, per board and per transport

The bundled 22-button handset is dual-mode, and every board maps it differently. Nobody has ever
checked those maps against the printed buttons — they were transcribed from whatever the hardware
happened to emit. Two of them contradict each other on the same physical key.

## Established

Read off `docs/r69/board.md`, `docs/h96max-h313/board.md` and the 2026-09-07 BLE capture on the
3518D.

| Button      | R69, IR      | H96 Max, IR     | 3518D, BLE (after the `hwdb` override) |
| ----------- | ------------ | --------------- | -------------------------------------- |
| Cog         | `KEY_SETUP`  | `KEY_F13`       | `KEY_SETUP`                            |
| OK (centre) | `KEY_ENTER`  | `KEY_REPLY`     | `KEY_OK`                               |
| Home        | `KEY_HOME`   | `KEY_HOME`      | `KEY_HOMEPAGE`                         |
| Voice       | `KEY_HELP`   | `KEY_F14`       | `KEY_SEARCH`                           |
| P +/-       | `KEY_PAGEUP` | `KEY_CHANNELUP` | `KEY_CHANNELUP`                        |
| Prime Video | `KEY_F3`     | `KEY_F8`        | `KEY_PROG3`                            |
| Google Play | `KEY_F8`     | `KEY_F9`        | `KEY_PROG4`                            |

Three buttons get three different keycodes across three boards. `KEY_F13`/`KEY_F14` for cog and
voice are placeholders, not meanings; `KEY_PAGEUP` for a channel rocker on a TV box is wrong;
`KEY_HOME` is "start of line" where `KEY_HOMEPAGE` is the TV home key.

## The shared USB id is not a shared layout

All three boards' worklogs record their bundled remote as `2B54:1600`, each measured on that board,
so the 3518D's `bt-remote.hwdb` would **match** on all three. It does not follow that it is
**right** on all three: the map names scancodes, it was built from the 3518D handset alone, and OEM
remotes reuse ids across layouts. ❓ on the R69 and H96 Max until someone captures their scancodes.

## Open

- **Does the IR table in each `board.dts` need a patch?** The `ir_keyN` scancode-to-keycode pairs
  are ours. Decide the correct keycode per printed button once, then make every board's table agree
  with it and with the BLE map.
- **Does the BLE `hwdb` need more overrides?** `firmware/h96max-3518d/bt-remote.hwdb` fixes nine
  usages today, ✅ verified on the handset. The remaining gap is the four app shortcuts; everything
  else on that remote now matches its printed button.
- **Converge the app shortcuts on `KEY_PROG1`…`KEY_PROG4`.** Settled on BLE, 2026-09-07: `c0056`
  `c003b` `c003d` `c003e` are YouTube, Netflix, Prime Video, Google Play in that order. The two IR
  tables use `KEY_F*` and disagree with each other, so they are the ones to change — `KEY_PROG*` is
  the keycode Linux defines for programmable app keys.

## Done means

Every board, both transports: no `KEY_UNKNOWN`, no duplicate keycodes, each keycode matching the
printed label, and the two transports agreeing button for button. The criteria are in
`docs/board-validation.md`; the procedure and the override mechanism are in `docs/remote-keymap.md`.

## Why it was deferred

The 3518D has no IR receiver, so its BLE map was the only one blocking that board's bring-up. The
R69 and H96 Max both work today with the keycodes they have — this is a correctness and consistency
debt, not a fault.
