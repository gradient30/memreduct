"""Expose the isolated fake Mihomo HTTP server through a Windows named pipe."""

import ctypes
from ctypes import wintypes
from pathlib import Path
import re
import socket
import sys


kernel = ctypes.WinDLL("kernel32", use_last_error=True)
kernel.CreateNamedPipeW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID]
kernel.CreateNamedPipeW.restype = wintypes.HANDLE
kernel.ConnectNamedPipe.argtypes = [wintypes.HANDLE, wintypes.LPVOID]
kernel.ReadFile.argtypes = [wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
kernel.WriteFile.argtypes = [wintypes.HANDLE, wintypes.LPCVOID, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID]
kernel.FlushFileBuffers.argtypes = [wintypes.HANDLE]
kernel.DisconnectNamedPipe.argtypes = [wintypes.HANDLE]
kernel.CloseHandle.argtypes = [wintypes.HANDLE]
invalid = ctypes.c_void_p(-1).value
pipe_name, port, ready = sys.argv[1], int(sys.argv[2]), Path(sys.argv[3])

while True:
    handle = kernel.CreateNamedPipeW(r"\\.\pipe" + "\\" + pipe_name, 3, 0, 1, 65536, 65536, 5000, None)
    if handle == invalid:
        raise ctypes.WinError(ctypes.get_last_error())
    ready.write_text("ready", encoding="ascii")
    try:
        if not kernel.ConnectNamedPipe(handle, None) and ctypes.get_last_error() != 535:
            raise ctypes.WinError(ctypes.get_last_error())
        request = b""
        expected = None
        while expected is None or len(request) < expected:
            buffer = ctypes.create_string_buffer(8192)
            count = wintypes.DWORD()
            if not kernel.ReadFile(handle, buffer, len(buffer), ctypes.byref(count), None) or not count.value:
                break
            request += buffer.raw[:count.value]
            if expected is None and b"\r\n\r\n" in request:
                head, _ = request.split(b"\r\n\r\n", 1)
                match = re.search(br"(?im)^Content-Length:\s*(\d+)", head)
                expected = len(head) + 4 + (int(match.group(1)) if match else 0)
        if request:
            with socket.create_connection(("127.0.0.1", port), timeout=8) as upstream:
                upstream.sendall(request)
                response = b""
                while True:
                    block = upstream.recv(65536)
                    if not block:
                        break
                    response += block
            sent = wintypes.DWORD()
            kernel.WriteFile(handle, response, len(response), ctypes.byref(sent), None)
            kernel.FlushFileBuffers(handle)
    finally:
        kernel.DisconnectNamedPipe(handle)
        kernel.CloseHandle(handle)
