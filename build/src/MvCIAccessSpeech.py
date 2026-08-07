"""
MvCIAccess speech companion.

The mod (Lua, inside the game) cannot call a DLL directly, so it writes what it
wants spoken into a small file; this program watches that file and speaks each
new line through NVDA.

Runs silently in the background. Exits automatically when the game closes, so
the user never has to manage it.
"""

import ctypes
import os
import sys
import time

APP_DIR = os.path.join(os.environ.get("LOCALAPPDATA", os.path.expanduser("~")),
                       "MvCIAccess")
SPEECH_PATH = os.path.join(APP_DIR, "speech.txt")
LOG_PATH = os.path.join(APP_DIR, "speech_companion.log")

GAME_PROCESS = "MVCI.exe"
IDLE_EXIT_SECONDS = 120     # quit if the game never appears / has gone away


def log(msg):
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + str(msg) + "\n")
    except Exception:
        pass


def dll_path():
    """The NVDA client DLL ships next to this executable."""
    if getattr(sys, "frozen", False):
        here = os.path.dirname(sys.executable)
    else:
        here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(here, "nvdaControllerClient64.dll")


def load_nvda():
    path = dll_path()
    if not os.path.isfile(path):
        log("ERROR: nvdaControllerClient64.dll not found at %s" % path)
        return None
    try:
        nvda = ctypes.CDLL(path)
    except Exception as e:
        log("ERROR loading DLL: %r" % (e,))
        return None
    nvda.nvdaController_speakText.argtypes = [ctypes.c_wchar_p]
    nvda.nvdaController_speakText.restype = ctypes.c_ulong
    nvda.nvdaController_cancelSpeech.argtypes = []
    nvda.nvdaController_cancelSpeech.restype = ctypes.c_ulong
    nvda.nvdaController_testIfRunning.argtypes = []
    nvda.nvdaController_testIfRunning.restype = ctypes.c_ulong
    return nvda


def game_running():
    """True while the game process exists (so we can exit with it)."""
    try:
        import subprocess
        flags = 0x08000000  # CREATE_NO_WINDOW
        out = subprocess.check_output(
            ["tasklist", "/FI", "IMAGENAME eq " + GAME_PROCESS],
            creationflags=flags, stderr=subprocess.DEVNULL)
        return GAME_PROCESS.lower().encode() in out.lower()
    except Exception:
        return True  # if we cannot tell, keep running


def speak(nvda, text, interrupt):
    if interrupt:
        try:
            nvda.nvdaController_cancelSpeech()
        except Exception:
            pass
    nvda.nvdaController_speakText(text)


def read_pipe():
    """(sequence, interrupt, text) or None."""
    try:
        with open(SPEECH_PATH, "r", encoding="utf-8") as f:
            data = f.read()
    except Exception:
        return None
    lines = data.split("\n")
    if len(lines) < 3:
        return None
    seq = lines[0].strip()
    if not seq:
        return None
    return seq, lines[1].strip() == "1", "\n".join(lines[2:]).strip()


def main():
    os.makedirs(APP_DIR, exist_ok=True)
    nvda = load_nvda()
    if nvda is None:
        return 1
    log("companion started")

    last_seq = None
    last_seen_game = time.time()

    while True:
        # exit once the game has been gone for a while
        if game_running():
            last_seen_game = time.time()
        elif time.time() - last_seen_game > IDLE_EXIT_SECONDS:
            log("game gone - exiting")
            return 0

        r = read_pipe()
        if r is not None:
            seq, interrupt, text = r
            if seq != last_seq and text:
                last_seq = seq
                try:
                    speak(nvda, text, interrupt)
                except Exception as e:
                    log("speak error: %r" % (e,))
        time.sleep(0.03)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        pass
    except Exception as e:
        log("fatal: %r" % (e,))
        sys.exit(1)
