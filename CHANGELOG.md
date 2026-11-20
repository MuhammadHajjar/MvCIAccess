# MvCIAccess changelog

## 2.0.0 (2026-11-20)

New:

- Fights now talk. You hear who's fighting, when a fighter goes down, when a
  fighter is at half or low health, each new bar of meter, 30 and 10 seconds
  left, time up, and who won.
- New keys in a fight: Ctrl+Shift+H for health, Ctrl+Shift+M for meter,
  Ctrl+Shift+T for time, and Ctrl+Shift+P for where your opponent is.
- Dialogs and warnings are now read with their choices, like the one that
  warns New Game will overwrite your story save.
- The title screen now says "Press any button", and loading screens say
  "Loading".
- Menus now read the help line under each item.
- Screens now say their name when you open them.
- Missing option values are now read, like volume levels, checkboxes, settings
  that are On, and the resolution.
- Ranked Match, Casual Match and Beginners League now read.
- Battle Settings on character select now reads.
- The opponent's team is now read on character select.
- The Battle Over menu after a match now reads.
- Pause menus with more than one page now say which page you're on.
- Both pages of the Story pause menu now read, including win conditions and
  each fighter's boosts.
- Tutorial tips in Story fights now read.
- Pausing a Story cutscene now tells you how to resume or skip.
- Mission Mode now reads, including each mission's instructions and the task
  while you play it.
- The Mission Mode pause menu now reads.
- Collection now reads, including the fighter list and biographies in The
  Stark-Light Library.
- The Controls Guide is now read out.
- The language list now says each language's name.

Fixed:

- Fixed character select going silent the second time you opened it.
- Fixed the mod sometimes going silent or crashing the game.
- Fixed the game stuttering while menus were being read.
- Fixed "Game already running" when starting the game soon after quitting.
- Fixed some screens staying silent the second time you opened them, like the
  pause menu, the command list and key config.
- Fixed character select not reading your fighter when you came back from
  Battle Settings or Team Select.
- Fixed some lines being read twice, and some being cut off.
- Speech is faster.

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
