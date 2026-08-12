"""
MvCIAccess installer.

Finds the Steam copy of Marvel vs. Capcom: Infinite, installs the accessibility
mod into it, and checks GitHub for newer releases.

Deliberately a console program: consoles are fully accessible to NVDA, whereas a
custom GUI usually is not. It prints plainly and asks simple y/n questions.
"""

import ctypes
import json
import os
import shutil
import sys
import time
import urllib.request

APP_NAME = "MvCIAccess"
VERSION = "1.2.0"
GITHUB_REPO = "MuhammadHajjar/MvCIAccess"   # set before publishing
APPID = "493840"
GAME_SUBPATH = os.path.join("steamapps", "common",
                            "MARVEL VS. CAPCOM INFINITE", "MVCI", "Binaries", "Win64")
GAME_EXE = "MVCI.exe"

APP_DIR = os.path.join(os.environ.get("LOCALAPPDATA", os.path.expanduser("~")), APP_NAME)


# ---------------------------------------------------------------- utilities

def out(msg=""):
    print(msg, flush=True)


def ask_yes(question, default=True):
    suffix = " [Y/n] " if default else " [y/N] "
    while True:
        try:
            answer = input(question + suffix).strip().lower()
        except EOFError:
            return default
        if answer == "":
            return default
        if answer in ("y", "yes"):
            return True
        if answer in ("n", "no"):
            return False


def payload_dir():
    """Files bundled inside this executable (PyInstaller unpacks to _MEIPASS)."""
    if getattr(sys, "frozen", False):
        return os.path.join(sys._MEIPASS, "payload")
    return os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "payload")


# ------------------------------------------------------------ steam locating

def steam_root():
    """Steam's install folder, from the registry."""
    import winreg
    for hive, key in ((winreg.HKEY_CURRENT_USER, r"Software\Valve\Steam"),
                      (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\Valve\Steam"),
                      (winreg.HKEY_LOCAL_MACHINE, r"SOFTWARE\Valve\Steam")):
        try:
            with winreg.OpenKey(hive, key) as k:
                for name in ("SteamPath", "InstallPath"):
                    try:
                        path = winreg.QueryValueEx(k, name)[0]
                        if path and os.path.isdir(path):
                            return path.replace("/", "\\")
                    except FileNotFoundError:
                        continue
        except OSError:
            continue
    return None


def steam_libraries(root):
    """Every Steam library folder, so games on other drives are found too."""
    libs = []
    if root:
        libs.append(root)
        vdf = os.path.join(root, "steamapps", "libraryfolders.vdf")
        try:
            with open(vdf, "r", encoding="utf-8", errors="ignore") as f:
                for line in f:
                    line = line.strip()
                    # entries look like:  "path"  "D:\\SteamLibrary"
                    if '"path"' in line:
                        parts = line.split('"')
                        if len(parts) >= 4:
                            p = parts[3].replace("\\\\", "\\")
                            if os.path.isdir(p):
                                libs.append(p)
        except OSError:
            pass
    return libs


def find_game():
    """The game's Win64 folder, or None."""
    for lib in steam_libraries(steam_root()):
        candidate = os.path.join(lib, GAME_SUBPATH)
        if os.path.isfile(os.path.join(candidate, GAME_EXE)):
            return candidate
    return None


# ----------------------------------------------------------------- installing

def copy_tree(src, dst):
    count = 0
    for root, _dirs, files in os.walk(src):
        rel = os.path.relpath(root, src)
        target = dst if rel == "." else os.path.join(dst, rel)
        os.makedirs(target, exist_ok=True)
        for name in files:
            shutil.copy2(os.path.join(root, name), os.path.join(target, name))
            count += 1
    return count


def install(game_dir):
    src = payload_dir()
    if not os.path.isdir(src):
        out("ERROR: the installer is missing its payload. Please re-download it.")
        return False

    out("Installing to:")
    out("  " + game_dir)
    n = copy_tree(src, game_dir)
    out("Copied %d files." % n)

    os.makedirs(APP_DIR, exist_ok=True)

    # tell the mod where the speech companion went, so it can start it itself
    companion = os.path.join(game_dir, "MvCIAccessSpeech.exe")
    with open(os.path.join(APP_DIR, "companion_path.txt"), "w", encoding="utf-8") as f:
        f.write(companion + "\n")

    # record what is installed, for the updater
    with open(os.path.join(APP_DIR, "version.txt"), "w", encoding="utf-8") as f:
        f.write(VERSION + "\n")
    with open(os.path.join(APP_DIR, "install_path.txt"), "w", encoding="utf-8") as f:
        f.write(game_dir + "\n")
    return True


def uninstall(game_dir):
    """Remove only what we installed; never touch the game's own files."""
    targets = [
        os.path.join(game_dir, "dwmapi.dll"),
        os.path.join(game_dir, "MvCIAccessSpeech.exe"),
        os.path.join(game_dir, "nvdaControllerClient64.dll"),
    ]
    removed = 0
    for t in targets:
        try:
            if os.path.isfile(t):
                os.remove(t)
                removed += 1
        except OSError as e:
            out("Could not remove %s (%s)" % (t, e))
    ue4ss = os.path.join(game_dir, "ue4ss")
    if os.path.isdir(ue4ss):
        try:
            shutil.rmtree(ue4ss)
            removed += 1
        except OSError as e:
            out("Could not remove the ue4ss folder (%s)" % e)
    out("Removed %d items. The game itself was not modified." % removed)
    return True


# ------------------------------------------------------------------ updating

def latest_release():
    """(tag, url) of the newest GitHub release, or (None, None)."""
    if "REPLACE_WITH" in GITHUB_REPO:
        return None, None
    url = "https://api.github.com/repos/%s/releases/latest" % GITHUB_REPO
    try:
        req = urllib.request.Request(url, headers={
            "Accept": "application/vnd.github+json",
            "User-Agent": APP_NAME + "/" + VERSION,
        })
        with urllib.request.urlopen(req, timeout=10) as r:
            data = json.load(r)
        tag = (data.get("tag_name") or "").lstrip("v")
        page = data.get("html_url")
        for asset in data.get("assets", []):
            if asset.get("name", "").lower().endswith(".exe"):
                return tag, asset.get("browser_download_url")
        return tag, page
    except Exception:
        return None, None


def newer(a, b):
    """True if version a is newer than b."""
    def parts(v):
        result = []
        for chunk in str(v).split("."):
            digits = "".join(c for c in chunk if c.isdigit())
            result.append(int(digits) if digits else 0)
        return result
    return parts(a) > parts(b)


def check_for_update():
    tag, url = latest_release()
    if not tag:
        return
    if newer(tag, VERSION):
        out("")
        out("A newer version is available: %s (you have %s)." % (tag, VERSION))
        out("Download it from:")
        out("  " + str(url))
    else:
        out("You have the latest version (%s)." % VERSION)


# --------------------------------------------------------------------- main

def main():
    try:
        ctypes.windll.kernel32.SetConsoleTitleW(APP_NAME + " Setup " + VERSION)
    except Exception:
        pass

    out("=" * 60)
    out(" %s Setup  version %s" % (APP_NAME, VERSION))
    out(" Screen reader accessibility for Marvel vs. Capcom: Infinite")
    out("=" * 60)
    out()

    out("Looking for the Steam version of the game...")
    game_dir = find_game()

    if not game_dir:
        out("Could not find it automatically.")
        out("This mod only works with the STEAM version (not the Microsoft Store one).")
        out()
        out("If you know where it is, paste the folder that contains MVCI.exe")
        out(r"  (it looks like ...\MARVEL VS. CAPCOM INFINITE\MVCI\Binaries\Win64)")
        out("or just press Enter to quit.")
        try:
            typed = input("> ").strip().strip('"')
        except EOFError:
            typed = ""
        if typed and os.path.isfile(os.path.join(typed, GAME_EXE)):
            game_dir = typed
        else:
            out("No game folder given. Nothing was changed.")
            return 1

    out("Found the game.")
    out()

    already = os.path.isdir(os.path.join(game_dir, "ue4ss", "Mods", APP_NAME))
    if already:
        out("%s is already installed here." % APP_NAME)
        if ask_yes("Do you want to REMOVE it?", default=False):
            uninstall(game_dir)
            out()
            out("Done. Press Enter to close.")
            input()
            return 0
        if not ask_yes("Re-install / update it instead?", default=True):
            out("Nothing was changed.")
            return 0
    else:
        if not ask_yes("Install the accessibility mod now?", default=True):
            out("Nothing was changed.")
            return 0

    out()
    if not install(game_dir):
        out("Installation failed.")
        input("Press Enter to close.")
        return 1

    out()
    out("Installation complete.")
    out()
    out("How to use it:")
    out("  1. Make sure NVDA is running.")
    out("  2. Start the game from Steam as usual.")
    out("  3. Menus are read automatically. The speech helper starts by itself.")
    out()
    out("In-game keys:")
    out("  Ctrl+Shift+A   re-read the current selection")
    out("  Ctrl+Shift+Z   repeat the last thing spoken")
    out()
    try:
        check_for_update()
    except Exception:
        pass
    out()
    out("Press Enter to close.")
    try:
        input()
    except EOFError:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
