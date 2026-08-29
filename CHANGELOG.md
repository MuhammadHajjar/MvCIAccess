# MvCIAccess changelog

## 1.2.1 (2026-08-29)

- All six Infinity Stones are now named on the stone picker: Reality, Power,
  Space, Time, Mind and Soul. You hear the name first, then what it does.
  Thanks to Xvordan on audiogames.net, who posted the names alongside the
  descriptions the mod was already reading. That made it possible to verify the
  mapping rather than take it on trust: two of the six matched text already
  captured from the game word for word, and all six were confirmed in game.
- A stone whose description is not recognised is still read out without a name
  rather than guessed at, and the unrecognised wording is logged so it can be
  added later.

## 1.2.0 (2026-08-12)

- The costume and color panel that opens after you pick a fighter now reads.
  You hear the row and its value, so "Costume, Normal" and "Color, 2".
- The Infinity Stone picker now reads. The stones are described rather than
  named: the game never puts a stone's name in text anywhere on that screen,
  only a picture and a description, so you hear what the stone does. Names are
  not invented, for the same reason the roster never guessed a fighter's name.
- Fixed the reader priority bug that made both of those screens silent in the
  first place. Once a screen matched it was pinned and became the only one
  checked, so character select kept answering for panels that had opened on top
  of it. Anything outranking the pinned screen is now re-checked every tick.

Known issue: the mod still costs more game thread time than it should, which
shows up as occasional sluggishness. Developer builds now measure it per reader,
and that measurement is what the next release is aimed at.

## 1.1.0 (2026-08-07)

- All 6 DLC characters are now named on character select: Sigma, Monster Hunter,
  Winter Soldier, Black Widow, Venom and Black Panther. Thanks to Kong on
  audiogames.net, who owns the DLC and mapped them.
- Fixed the roster side announced for the DLC row. It was worked out from where
  a fighter sits on screen, which is right for the base roster but wrong for the
  DLC row, since that row is 2 Capcom and 4 Marvel rather than an even split.
  Winter Soldier, for example, was being called Capcom side.

## 1.0.0 (2026-08-06)

First release.

Reads through NVDA:

- Title screen and main menu
- Settings and its sub-screens (Sound, System, Display, Language), including
  option values, re-spoken when you change them
- Story and Battle submenus, and the Online menu
- Keyboard Settings and Controller Settings
- Stage select
- Character select, with fighter name, roster side, row and column
- Pause menu in Training, Arcade and Versus
- Story mode's pause panel (win conditions, character conditions, buffs)
- Command List, with the input notation decoded from the game's icons

Other:

- Single installer that finds the Steam install itself (including other drives),
  and supports update and uninstall
- Speech helper starts automatically with the game
- All 30 base characters named (mapped by hand in game)

Not covered yet: online sub-menus, costume/color and Infinity Stone pickers,
Collection, Mission Mode, in-match HUD, HUD Position, bound-key icons, and the
6 DLC character names.
