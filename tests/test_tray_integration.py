"""Exercise the real notification icon on an interactive Windows desktop.

Run against an isolated test build compiled with APP_NO_MUTEX so the user's
installed instance can keep running. The executable must be in a writable,
temporary directory: the test creates a portable configuration beside it.
"""

import argparse
import ctypes
from ctypes import wintypes
from pathlib import Path
import subprocess
import sys
import time
import unittest


UID = 1337
WM_COMMAND = 0x0111
WM_SYSCOMMAND = 0x0112
WM_LBUTTONDOWN = 0x0201
RM_TASKBARCREATED = 0x8000 + 7
RM_TRAYICON = 0x8000 + 11
SC_MINIMIZE = 0xF020
SC_CLOSE = 0xF060
IDM_EXIT = 155


class GUID(ctypes.Structure):
    _fields_ = [("data1", wintypes.DWORD), ("data2", wintypes.WORD),
                ("data3", wintypes.WORD), ("data4", ctypes.c_ubyte * 8)]


class NOTIFYICONIDENTIFIER(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.DWORD), ("hWnd", wintypes.HWND),
                ("uID", wintypes.UINT), ("guidItem", GUID)]


user32 = ctypes.WinDLL("user32", use_last_error=True)
shell32 = ctypes.WinDLL("shell32", use_last_error=True)
ENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
user32.EnumWindows.argtypes = [ENUMPROC, wintypes.LPARAM]
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.GetClassNameW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
shell32.Shell_NotifyIconGetRect.argtypes = [ctypes.POINTER(NOTIFYICONIDENTIFIER), ctypes.POINTER(wintypes.RECT)]
shell32.Shell_NotifyIconGetRect.restype = ctypes.c_long


def wait_for(predicate, message, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.1)
    raise AssertionError(message)


def main_window(pid):
    windows = []

    @ENUMPROC
    def callback(hwnd, _):
        owner = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(owner))
        name = ctypes.create_unicode_buffer(256)
        user32.GetClassNameW(hwnd, name, len(name))
        if owner.value == pid and name.value == "#32770":
            windows.append(hwnd)
        return True

    user32.EnumWindows(callback, 0)
    return windows[0] if windows else None


def tray_present(hwnd):
    ident = NOTIFYICONIDENTIFIER()
    ident.cbSize = ctypes.sizeof(ident)
    ident.hWnd = hwnd
    ident.uID = UID
    rect = wintypes.RECT()
    # Explorer can return S_FALSE when the icon is in its overflow area.
    return shell32.Shell_NotifyIconGetRect(ctypes.byref(ident), ctypes.byref(rect)) >= 0


class TrayIntegrationTest(unittest.TestCase):
    def test_minimize_close_restore_and_taskbar_recreation(self):
        exe = Path(TEST_EXE).resolve()
        ini = exe.with_name("memreduct.ini")
        if ini.exists():
            self.fail(f"Refusing to overwrite existing configuration: {ini}")
        ini.write_text("[memreduct]\nCheckUpdatesPeriod=0\n", encoding="utf-16")
        proc = subprocess.Popen([str(exe), "-portable"], cwd=exe.parent)
        hwnd = None
        try:
            def find_window():
                if proc.poll() is not None:
                    self.fail(f"Test process exited early: {proc.returncode}; build with APP_NO_MUTEX")
                return main_window(proc.pid)

            hwnd = wait_for(find_window, "The test application did not create a main window")
            wait_for(lambda: user32.IsWindowVisible(hwnd), "The test window did not become visible")
            wait_for(lambda: tray_present(hwnd), "The application's notification icon is missing")

            for command in (SC_MINIMIZE, SC_CLOSE):
                self.assertTrue(user32.PostMessageW(hwnd, WM_SYSCOMMAND, command, 0))
                wait_for(lambda: not user32.IsWindowVisible(hwnd), "Window did not hide")
                wait_for(lambda: tray_present(hwnd), "Notification icon disappeared after hiding")
                self.assertTrue(user32.PostMessageW(hwnd, RM_TRAYICON, 0, (UID << 16) | WM_LBUTTONDOWN))
                wait_for(lambda: user32.IsWindowVisible(hwnd), "Tray click did not restore the window")

            self.assertTrue(user32.PostMessageW(hwnd, RM_TASKBARCREATED, 0, 0))
            wait_for(lambda: tray_present(hwnd), "Notification icon was not restored after taskbar recreation")
        finally:
            if hwnd:
                user32.PostMessageW(hwnd, WM_COMMAND, IDM_EXIT, 0)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.terminate()
                proc.wait(timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--exe", required=True, help="path to an isolated APP_NO_MUTEX build")
    args, remaining = parser.parse_known_args()
    TEST_EXE = args.exe
    unittest.main(argv=[sys.argv[0], *remaining])
