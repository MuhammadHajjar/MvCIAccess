"""
MvCIAccess speech companion.

The mod (Lua, inside the game) cannot call a DLL directly, so it writes what it
wants spoken into a small file; this program watches that file and speaks each
new line through NVDA.

Runs silently in the background. Exits automatically when the game closes, so
the user never has to manage it.
"""

import ctypes
import ctypes.wintypes as wt
import os
import sys
import time

APP_DIR = os.path.join(os.environ.get("LOCALAPPDATA", os.path.expanduser("~")),
                       "MvCIAccess")
SPEECH_PATH = os.path.join(APP_DIR, "speech.txt")
LOG_PATH = os.path.join(APP_DIR, "speech_companion.log")

GAME_PROCESS = "mvci.exe"
POLL_SECONDS = 0.03          # how often speech.txt is looked at
PROCESS_CHECK_SECONDS = 1.0  # how often we look for the game process
STARTUP_GRACE_SECONDS = 120  # the game may take this long to show up
# Once the game has been seen and is gone, leave at once. Steam starts this
# program as part of the game, so for as long as it lingers Steam shows the game
# as still running and refuses to start it again ("Game already running").
GONE_EXIT_SECONDS = 3


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


# --- is the game running? ---------------------------------------------------
# Asked through the process snapshot API. This used to shell out to tasklist on
# every pass of the loop, which took about 160 ms a time, so the "30 ms" speech
# poll really ran five times a second and every announcement waited on it.

class PROCESSENTRY32W(ctypes.Structure):
    _fields_ = [
        ("dwSize", wt.DWORD), ("cntUsage", wt.DWORD), ("th32ProcessID", wt.DWORD),
        ("th32DefaultHeapID", ctypes.c_size_t), ("th32ModuleID", wt.DWORD),
        ("cntThreads", wt.DWORD), ("th32ParentProcessID", wt.DWORD),
        ("pcPriClassBase", wt.LONG), ("dwFlags", wt.DWORD),
        ("szExeFile", wt.WCHAR * 260),
    ]


_k32 = ctypes.WinDLL("kernel32", use_last_error=True)
_k32.CreateToolhelp32Snapshot.argtypes = [wt.DWORD, wt.DWORD]
_k32.CreateToolhelp32Snapshot.restype = wt.HANDLE
_k32.Process32FirstW.argtypes = [wt.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]
_k32.Process32FirstW.restype = wt.BOOL
_k32.Process32NextW.argtypes = [wt.HANDLE, ctypes.POINTER(PROCESSENTRY32W)]
_k32.Process32NextW.restype = wt.BOOL
_k32.CloseHandle.argtypes = [wt.HANDLE]
_k32.CreateMutexW.argtypes = [ctypes.c_void_p, wt.BOOL, wt.LPCWSTR]
_k32.CreateMutexW.restype = wt.HANDLE

TH32CS_SNAPPROCESS = 0x2
INVALID_HANDLE = wt.HANDLE(-1).value
ERROR_ALREADY_EXISTS = 183


def game_running():
    """True while the game process exists. True too if we cannot tell."""
    snap = _k32.CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
    if not snap or snap == INVALID_HANDLE:
        return True
    try:
        entry = PROCESSENTRY32W()
        entry.dwSize = ctypes.sizeof(PROCESSENTRY32W)
        ok = _k32.Process32FirstW(snap, ctypes.byref(entry))
        while ok:
            if entry.szExeFile.lower() == GAME_PROCESS:
                return True
            ok = _k32.Process32NextW(snap, ctypes.byref(entry))
        return False
    finally:
        _k32.CloseHandle(snap)


def already_running():
    """One companion only: two would speak every line twice."""
    _k32.CreateMutexW(None, False, "Local\\MvCIAccessSpeech")
    return ctypes.get_last_error() == ERROR_ALREADY_EXISTS


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
    if already_running():
        return 0
    nvda = load_nvda()
    if nvda is None:
        return 1
    log("companion started")

    # Whatever is in the slot when the game is not running yet was left by an
    # earlier session (the companion was started by hand): do not speak it.
    last_seq = None
    if not game_running():
        r = read_pipe()
        last_seq = r[0] if r else None
    # monotonic: a clock change must not stop us noticing the game has gone
    started = time.monotonic()
    seen_game = False
    last_seen_game = started
    next_check = 0.0

    while True:
        now = time.monotonic()
        if now >= next_check:
            next_check = now + PROCESS_CHECK_SECONDS
            if game_running():
                seen_game = True
                last_seen_game = now
            elif seen_game and now - last_seen_game > GONE_EXIT_SECONDS:
                log("game gone - exiting")
                return 0
            elif not seen_game and now - started > STARTUP_GRACE_SECONDS:
                log("game never appeared - exiting")
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
        time.sleep(POLL_SECONDS)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        pass
    except Exception as e:
        log("fatal: %r" % (e,))
        sys.exit(1)
