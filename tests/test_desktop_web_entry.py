"""Inspect the compiled Windows menu and dialog resources without launching the app."""
import ctypes
from ctypes import wintypes
from pathlib import Path
import sys

kernel = ctypes.WinDLL('kernel32', use_last_error=True)
user = ctypes.WinDLL('user32', use_last_error=True)
kernel.LoadLibraryExW.argtypes = [wintypes.LPCWSTR, wintypes.HANDLE, wintypes.DWORD]
kernel.LoadLibraryExW.restype = wintypes.HMODULE
kernel.FreeLibrary.argtypes = [wintypes.HMODULE]
user.LoadMenuW.argtypes = [wintypes.HINSTANCE, wintypes.LPCWSTR]
user.LoadMenuW.restype = wintypes.HMENU
user.GetSubMenu.argtypes = [wintypes.HMENU, ctypes.c_int]
user.GetSubMenu.restype = wintypes.HMENU
user.GetMenuItemCount.argtypes = [wintypes.HMENU]
user.GetMenuItemID.argtypes = [wintypes.HMENU, ctypes.c_int]
user.GetMenuItemID.restype = wintypes.UINT
user.DestroyMenu.argtypes = [wintypes.HMENU]
user.GetDlgItem.argtypes = [wintypes.HWND, ctypes.c_int]
user.GetDlgItem.restype = wintypes.HWND
user.DestroyWindow.argtypes = [wintypes.HWND]
user.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
user.LoadStringW.argtypes = [wintypes.HINSTANCE, wintypes.UINT, wintypes.LPWSTR, ctypes.c_int]
PROC = ctypes.WINFUNCTYPE(ctypes.c_ssize_t, wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM)
user.CreateDialogParamW.argtypes = [wintypes.HINSTANCE, wintypes.LPCWSTR, wintypes.HWND, PROC, wintypes.LPARAM]
user.CreateDialogParamW.restype = wintypes.HWND

def resource(number):
    return ctypes.cast(ctypes.c_void_p(number), wintypes.LPCWSTR)

module = kernel.LoadLibraryExW(sys.argv[1], None, 0x00000002)
if not module:
    raise ctypes.WinError(ctypes.get_last_error())
menu = dialog = None
try:
    assert 'http://127.0.0.1:8765/'.encode('utf-16le') in Path(sys.argv[1]).read_bytes(), 'Expected Web home URL is missing'
    menu = user.LoadMenuW(module, resource(101))
    if not menu:
        raise ctypes.WinError(ctypes.get_last_error())
    popup = user.GetSubMenu(menu, 0)
    items = [user.GetMenuItemID(popup, i) for i in range(user.GetMenuItemCount(popup))]
    assert 192 in items, 'Tray menu is missing the Web home entry'
    assert 171 not in items and 172 not in items, 'Tray menu still contains website or about'
    callback = PROC(lambda *_: 0)
    dialog = user.CreateDialogParamW(module, resource(100), None, callback, 0)
    if not dialog:
        raise ctypes.WinError(ctypes.get_last_error())
    clean = user.GetDlgItem(dialog, 103)
    web = user.GetDlgItem(dialog, 191)
    assert clean, 'Main cleanup button is missing'
    assert web, 'Main Web home button is missing'
    clean_rect, web_rect = wintypes.RECT(), wintypes.RECT()
    assert user.GetWindowRect(clean, ctypes.byref(clean_rect)) and user.GetWindowRect(web, ctypes.byref(web_rect))
    assert clean_rect.right <= web_rect.left and clean_rect.top == web_rect.top, 'Web button is not beside cleanup'
    label = ctypes.create_unicode_buffer(128)
    assert user.LoadStringW(module, 112, label, len(label)) and label.value == 'Web 主页', 'Web entry label is missing'
    print('PASS: compiled tray menu and main dialog contain the requested Web entry')
finally:
    if dialog:
        user.DestroyWindow(dialog)
    if menu:
        user.DestroyMenu(menu)
    kernel.FreeLibrary(module)
