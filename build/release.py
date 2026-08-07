"""
Build a new MvCIAccess release.

    vpython.exe release.py 1.1.0
    vpython.exe release.py 1.1.0 --repo YourName/MvCIAccess

What it does:
  1. copies the Lua files from the LIVE game install into the payload
     (the live install is the working copy we edit and test against)
  2. writes the new version number into the installer
  3. optionally sets the GitHub repo so auto-update works
  4. rebuilds MvCIAccess-Setup.exe

Everything is written UTF-8 WITHOUT a BOM. A BOM in mods.txt silently stops
UE4SS loading the mod, which cost us an evening once.
"""

import argparse
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PAYLOAD = os.path.join(HERE, "payload")
SRC = os.path.join(HERE, "src")
SETUP_PY = os.path.join(SRC, "MvCIAccessSetup.py")

LIVE_SCRIPTS = (r"C:\Program Files (x86)\Steam\steamapps\common"
                r"\MARVEL VS. CAPCOM INFINITE\MVCI\Binaries\Win64"
                r"\ue4ss\Mods\MvCIAccess\Scripts")
PAYLOAD_SCRIPTS = os.path.join(PAYLOAD, "ue4ss", "Mods", "MvCIAccess", "Scripts")

PYTHON = sys.executable


def write_no_bom(path, text):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def sync_scripts():
    if not os.path.isdir(LIVE_SCRIPTS):
        print("ERROR: cannot find the live install at:\n  " + LIVE_SCRIPTS)
        return 0
    os.makedirs(PAYLOAD_SCRIPTS, exist_ok=True)
    # drop any .lua in the payload that no longer exists live
    for name in os.listdir(PAYLOAD_SCRIPTS):
        if name.endswith(".lua") and not os.path.isfile(os.path.join(LIVE_SCRIPTS, name)):
            os.remove(os.path.join(PAYLOAD_SCRIPTS, name))
    n = 0
    for name in os.listdir(LIVE_SCRIPTS):
        if name.endswith(".lua"):
            shutil.copy2(os.path.join(LIVE_SCRIPTS, name),
                         os.path.join(PAYLOAD_SCRIPTS, name))
            n += 1
    return n


def set_version(version, repo=None):
    with open(SETUP_PY, "r", encoding="utf-8") as f:
        text = f.read()
    text = re.sub(r'^VERSION\s*=\s*".*?"',
                  'VERSION = "%s"' % version, text, count=1, flags=re.M)
    if repo:
        text = re.sub(r'^GITHUB_REPO\s*=\s*".*?"',
                      'GITHUB_REPO = "%s"' % repo, text, count=1, flags=re.M)
    write_no_bom(SETUP_PY, text)


def check_lua():
    """Parse-check every Lua file before shipping it."""
    try:
        from luaparser import ast
    except ImportError:
        print("  (luaparser not installed, skipping syntax check)")
        return True
    bad = 0
    for name in sorted(os.listdir(PAYLOAD_SCRIPTS)):
        if not name.endswith(".lua"):
            continue
        try:
            with open(os.path.join(PAYLOAD_SCRIPTS, name), "r", encoding="utf-8") as f:
                ast.parse(f.read())
        except Exception as e:
            print("  SYNTAX ERROR in %s: %s" % (name, str(e)[:120]))
            bad += 1
    return bad == 0


def build():
    cmd = [PYTHON, "-m", "PyInstaller", "--onefile", "--console", "--clean",
           "--distpath", os.path.join(HERE, "dist"),
           "--workpath", os.path.join(HERE, "work"),
           "--specpath", os.path.join(HERE, "work"),
           "--add-data", PAYLOAD + ";payload",
           "--name", "MvCIAccess-Setup", SETUP_PY]
    return subprocess.call(cmd, stdout=subprocess.DEVNULL) == 0


def main():
    p = argparse.ArgumentParser()
    p.add_argument("version", help="e.g. 1.1.0")
    p.add_argument("--repo", help="GitHub owner/repo, enables auto-update")
    args = p.parse_args()

    print("Syncing Lua from the live install...")
    n = sync_scripts()
    if not n:
        return 1
    print("  %d files" % n)

    print("Checking Lua syntax...")
    if not check_lua():
        print("ABORTED: fix the syntax errors first.")
        return 1
    print("  ok")

    print("Setting version %s%s..." % (args.version,
                                       (" repo " + args.repo) if args.repo else ""))
    set_version(args.version, args.repo)

    print("Building the installer (takes a minute)...")
    if not build():
        print("BUILD FAILED")
        return 1

    exe = os.path.join(HERE, "dist", "MvCIAccess-Setup.exe")
    size = os.path.getsize(exe) / (1024 * 1024)
    print("")
    print("Done: %s  (%.1f MB)" % (exe, size))
    print("Now update CHANGELOG.md and upload this file as version %s." % args.version)
    return 0


if __name__ == "__main__":
    sys.exit(main())
