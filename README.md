# MvCIAccess

An accessibility mod for **Marvel vs. Capcom: Infinite** on Steam that reads the
game's menus out loud through NVDA.

This is not full accessibility, and it is not trying to pretend otherwise. It is
a crutch that gets you through everything around the fight, which is the part
that was completely impossible before. The fighting itself is still on you.

## What it reads

- Title screen and main menu
- All of Settings, including Sound, System, Display and Language, with the
  values spoken too, so you hear "Subtitles, Battle, On" and you hear it change
  when you change it
- Story and Battle submenus, and the Online menu
- Keyboard Settings and Controller Settings
- Stage select
- Character select, with the fighter's name, roster side, row and column, for
  all 36 fighters including the 6 DLC characters
- The costume and color panel that opens once you pick a fighter
- The Infinity Stone picker. The stones are *described* rather than named,
  because the game never puts their names in text anywhere on that screen, only
  a picture and a description. So you hear what the stone does, not "Power"
- Pause menu in Training, Arcade and Versus
- Story mode's pause panel, with win conditions and active buffs
- The Command List, with the input notation decoded from the game's icons, so
  you hear "Shoryuken, dragon punch, Light Punch or Heavy Punch"

## What it does not read

- The actual match. No health, no meter, no timer, no combo counter.
- Online submenus. The Online menu itself reads, the screens under Ranked,
  Casual and Lobby do not.
- Collection, so all the art, movies, sound and database screens.
- Mission Mode.
- HUD Position, which is a visual layout tool.
- Which key a command is actually bound to in the controller and keyboard
  screens, because those are drawn as pictures rather than text.

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
| Ctrl+Shift+A | Re-read the current selection right now |
| Ctrl+Shift+Z | Repeat the last thing spoken |
| Ctrl+Shift+G | Reload the character name overrides |

## About the delay

There is some latency, and some of it is a deliberate trade rather than an
oversight. The mod inspects the game's live interface from inside the game,
which is expensive. Polling faster made the game stutter, and at one point lock
up. In a 60 fps fighting game a dropped frame is worse than an announcement
arriving a moment late, so it is tuned down on purpose. If a screen is slow to
speak, Ctrl+Shift+A reads it instantly.

Some of it is not a trade though, it is just cost that has not been paid down
yet. Developer builds time every reader, and measured over ~220 seconds of play
the readers used about 28% of the game thread, with single probes blocking for
13 to 35 ms against a 16.7 ms frame. The work is dominated by repeated engine
object lookups that mostly return "my screen is not open". Cutting that down is
the main open piece of work. Set a `devmode.txt` in the mod's data folder and it
writes `perf.txt` with per-reader call counts and timings.

## How it works

UE4SS loads a Lua mod into the game. The Lua walks the live Unreal objects to
work out which screen you are on and what is highlighted, then writes the text
to a small file. A separate companion program, `MvCIAccessSpeech.exe`, watches
that file and speaks it through NVDA's controller client.

The file bridge exists for a reason: UE4SS runs plain Lua 5.4 with no FFI, so the
mod cannot call a speech DLL directly. The companion is the part that can.

Two things are worth knowing if you want to work on this:

- Reading a UObject property **value** in bulk can hard crash the game with an
  access violation that `pcall` cannot catch. Enumerating property *names* is
  safe. Reading specific known properties is safe.
- Indexing a TArray out of bounds also hard crashes. Every array read here is
  bounds checked first, and that is not paranoia, it cost a few crashes to learn.

## Building from source

You need Python 3.9 or newer with PyInstaller.

```bash
python build/release.py 1.1.0
```

That syntax checks every Lua file, copies the current scripts into the payload,
stamps the version into the installer, and builds `build/dist/MvCIAccess-Setup.exe`.

Pass the repository to keep the built-in update check pointed at the right
place:

```bash
python build/release.py 1.1.0 --repo MuhammadHajjar/MvCIAccess
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
    main.lua                     bootstrap, hotkeys, the unified poller
    announcer.lua                writes text out to the speech bridge
    screen_*.lua                 one reader per screen
    inspector.lua                development-only discovery tool
```

## Help wanted

This is not stable and it is certainly full of bugs that have not been hit yet.

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
- Everyone in the [audiogames.net thread](https://forum.audiogames.net/) who
  tested and reported

## License

MIT, see [LICENSE](LICENSE). UE4SS is redistributed under its own MIT license,
included in the payload.
