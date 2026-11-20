# MvCIAccess

An accessibility mod for **Marvel vs. Capcom: Infinite** on Steam that reads the
game through NVDA: almost every screen, and what happens in a fight.

It is not full accessibility yet, and it does not pretend to be. Version 2.0 is
the biggest step towards it so far: you can get through the whole game around
the fight on your own, and the fight itself tells you who is fighting, who went
down, how much health and meter everyone has, and who won. Playing the fight
well is still on you.

## What it reads

- Title screen, main menu and every submenu, with the help line the game shows
  under each item
- Dialogs and warnings, with their choices, such as the one before New Game
  overwrites your story save
- All of Settings, including Sound, System, Display and Language, with values
  spoken too (volume levels, checkboxes, On and Off) and re-spoken when you
  change them
- Keyboard Settings and Controller Settings
- Online: Ranked Match, Casual Match, Beginners League, Lobby and Rankings
- Stage select
- Character select, with the fighter's name, roster side, row and column, for
  all 36 fighters including the 6 DLC characters, for your team and the
  opponent's
- The costume and color panel, the Infinity Stone picker with all six stones
  named, and Battle Settings
- Every pause menu, with page numbers where a menu has pages, including the
  Story pause menu's win conditions and each fighter's boosts
- The Command List, with the input notation decoded from the game's icons, so
  you hear "Shoryuken, dragon punch, Light Punch or Heavy Punch"
- The Controls Guide, which is a picture in the game, written out in words
- Tutorial tips in Story fights, and the pause screen of a Story cutscene
- Mission Mode: the tutorial, each mission's instructions, and the task while
  you play it
- Collection, including the fighter biographies in The Stark-Light Library
- The Battle Over menu after a match
- Fights: the line-up, a fighter going down, half and low health for any
  fighter, each new bar of meter, 30 and 10 seconds left, time up, and the
  result

## What it does not read yet

- The versus screen before a fight.
- Which fighters are in your Team Select presets.
- Which key a command is bound to in the controller and keyboard screens,
  because those are drawn as pictures rather than text.
- A continuous sense of where the opponent is during a fight. Ctrl+Shift+P
  tells you on demand.
- HUD Position is read as text only; it is a visual layout tool.

## Installing

Download `MvCIAccess-Setup.exe` from the
[latest release](https://github.com/MuhammadHajjar/MvCIAccess/releases/latest)
and run it. It finds your
Steam copy of the game by itself, including on a second drive, asks before it
changes anything, and that is it. Run it again later and it offers to update or
remove. Removing only deletes the mod's own files, it never touches the game.

Two things that look like problems but are not:

- Windows may say "Windows protected your PC" the first time you run it. That is
  because the file is not code signed, and a certificate costs money that a free
  mod does not have. Press More info, then Run anyway.
- Your browser may refuse to virus scan it because of its size. That is normal
  for a file this big.

You need the **Steam** version. The Microsoft Store version is sandboxed and
cannot be modded this way at all. You also need NVDA running. The speech helper
starts itself with the game, there is nothing extra to launch.

## Keys

| Key | What it does |
| --- | --- |
| Ctrl+Shift+A | Re-read the current screen right now |
| Ctrl+Shift+Z | Repeat the last thing spoken |
| Ctrl+Shift+G | Reload the character name overrides |
| Ctrl+Shift+H | In a fight: health of both teams |
| Ctrl+Shift+M | In a fight: Hyper Combo meter of both teams |
| Ctrl+Shift+T | In a fight: time left |
| Ctrl+Shift+P | In a fight: where the opponent is, and how far |

## Speed

The mod looks at the game four times a second. Up to 1.2 each look took 20 to
45 ms of the game's own time, more than a whole frame, which showed up as
stutter and as speech arriving late. In 2.0 a look takes about 2 ms, so it is
roughly ten times lighter on menus and far more than that on character select.
Developer builds measure it: put a `devmode.txt` in the mod's data folder and it
writes `perf.txt` with per-reader timings.

## How it works

UE4SS loads a Lua mod into the game. The Lua works out which screen you are on
and what is highlighted, then writes the text to a small file. A separate
companion program, `MvCIAccessSpeech.exe`, watches that file and speaks it
through NVDA's controller client.

The file bridge exists for a reason: UE4SS runs plain Lua 5.4 with no FFI, so the
mod cannot call a speech DLL directly. The companion is the part that can.

Things worth knowing if you want to work on this:

- `core.lua` answers "where am I" without searching the engine: the game's own
  flow actor (`GameFlowSystem:GetFlowBP()`), its popup controller, and UMG's
  `GetAllWidgetsOfClass`. `FindAllOf` costs about 19 ms whatever the class and
  must never run on every tick.
- Fight data comes from the game's own function library,
  `/Script/Duck.Default__UIFightBPLib` (health, meter, timer, fighters,
  positions).
- A null object reference arrives in Lua as a non-nil userdata, and calling a
  method on it is a native crash that `pcall` cannot catch. Check `IsValid()`
  first, always.
- Reading UObject property **values** in bulk, or indexing a TArray out of
  bounds, also hard crashes. Read specific known properties, bounds check every
  array.
- All of a mod's Lua runs in one Lua VM. Lua that allocates on the `LoopAsync`
  thread or inside a key-bind callback races the game thread and kills the mod.
  All real work happens in one game-thread tick.

## Building from source

You need Python 3.9 or newer with PyInstaller.

```bash
python build/release.py 2.0.0
```

That syntax checks every Lua file, copies the current scripts into the payload,
stamps the version into the installer, and builds `build/dist/MvCIAccess-Setup.exe`.

Pass the repository to keep the built-in update check pointed at the right
place:

```bash
python build/release.py 2.0.0 --repo MuhammadHajjar/MvCIAccess
```

Note that everything the mod loads is written UTF-8 **without** a BOM. A BOM in
`mods.txt` silently stops UE4SS loading the mod and gives you no error at all.

## Repository layout

```
build/release.py                 one command release build
build/src/MvCIAccessSetup.py     the installer
build/src/MvCIAccessSpeech.py    the NVDA speech companion
build/payload/                   exactly what gets installed into the game
  ue4ss/Mods/MvCIAccess/Scripts/ the mod itself
    main.lua                     bootstrap, hotkeys, the one game-thread tick
    core.lua                     where am I: flow, active menu, dialog, widgets
    announcer.lua                writes text out to the speech bridge
    screen_menu.lua              every menu, list, dialog and text page
    screen_fight.lua             fight events and the fight keys
    screen_*.lua                 the other screens with their own readers
    inspector.lua                development-only discovery tool
```

## Help wanted

There are certainly bugs that have not been hit yet.

The most useful bug report is **a screen that says nothing at all**, because
those are usually quick to add once someone knows they exist.
[Open an issue](https://github.com/MuhammadHajjar/MvCIAccess/issues) and say
which mode you were in and how you got there.

If you can read code, even better. This was built by someone who cannot see what
he was building, and it needs to grow.

## Credits

- [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) by Narknon and contributors, MIT
  licensed, which is the only reason any of this is possible
- The NVDA controller client, from [NV Access](https://www.nvaccess.org/)
- Kong on audiogames.net, who owns the DLC and mapped all 6 DLC fighters by ear
  so everyone else gets them for free
- Xvordan on audiogames.net, who supplied the Infinity Stone names together
  with each stone's in-game description, which is what made it possible to
  verify the mapping rather than trust it
- Everyone in the [audiogames.net thread](https://forum.audiogames.net/) who
  tested and reported

## License

MIT, see [LICENSE](LICENSE). UE4SS is redistributed under its own MIT license,
included in the payload.
