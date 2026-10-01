#!/usr/bin/env python3
# Map key strings to 86Box set-1 scancode events for the automation `key` command.
#
# The scancode VALUES are parsed at runtime from 86Box's own keymap
# (src/qt/xkbcommon_keyboard.cpp, the xkb_keycodes table). That table is the
# ground truth for this emulator: it is NOT plain set-1 (e.g. space is 0x39,
# not 0x00), so no generic set-1 library is used.
#
# Usage:  keymap.py <tap|down|up> KEY...
#   KEY is a raw scancode (0xNN) or a key string. A key string is either a
#   reserved named key (enter, tab, space, ...) or a literal run of characters
#   to type, e.g. "cd blood" types c,d,space,b,l,o,o,d. Uppercase letters and
#   shifted punctuation take a left-Shift around them.
#
# Output: one line per consecutive same-direction run, "down 0xNN ..." or
# "up 0xNN ...". The caller sends each line as `key <dir> <codes>`.

import os
import re
import sys

# --- locate 86Box's keymap source (trusted source) -------------------------
def _find_cpp():
    env = os.environ.get("BOX_XKB_CPP")
    if env:
        return env
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.abspath(os.path.join(here, "..", "..", "..", ".."))
    return os.path.join(root, "src", "qt", "xkbcommon_keyboard.cpp")

_ENTRY = re.compile(r'\{\s*"([A-Za-z0-9]+)"\s*,\s*0x([0-9a-fA-F]+)\s*\}')

def _xkb_table():
    """Parse xkb_keycodes {name: scancode} from 86Box's own source."""
    try:
        with open(_find_cpp(), encoding="utf-8") as f:
            src = f.read()
    except OSError as e:
        sys.exit(f"keymap: cannot read 86Box keymap source: {e}")
    start = src.find("xkb_keycodes")
    if start < 0:
        sys.exit("keymap: 'xkb_keycodes' not found in source")
    region = src[start:src.find("};", start)]
    table = {}
    for name, code in _ENTRY.findall(region):
        table.setdefault(name, int(code, 16))
    if "SPCE" not in table:
        sys.exit("keymap: parsed table looks wrong (no SPCE)")
    return table

XKB = _xkb_table()
SHIFT = XKB["LFSH"]

# --- standard US layout rows -> XKB geometry names --------------------------
# Generated from the fixed geometry, not hand-typed: name = row prefix + col.
def _row(prefix, chars):
    out = {}
    for i, ch in enumerate(chars, start=1):
        out[ch] = f"{prefix}{i:02d}"
    return out

CHAR = {}
CHAR.update(_row("AE", "1234567890-="))   # AE01..AE12
CHAR["`"] = "AE00"
CHAR.update(_row("AD", "qwertyuiop[]"))   # AD01..AD12
CHAR.update(_row("AC", "asdfghjkl;\x27"))   # AC01..AC11
CHAR["\\"] = "AC12"
CHAR.update(_row("AB", "zxcvbnm,./"))      # AB01..AB10
CHAR[" "] = "SPCE"

# shifted char -> the unshifted char it sits on (so ':' -> AC11, etc.)
SHIFTED = {}
def _shift_row(base, shifted):
    for b, s in zip(base, shifted):
        SHIFTED[s] = b
_shift_row("1234567890-=", "!@#$%^&*()_+")
_shift_row("qwertyuiop[]", "QWERTYUIOP{}")
_shift_row("asdfghjkl;\x27", "ASDFGHJKL:\"")
_shift_row("zxcvbnm,./", "ZXCVBNM<>?")
SHIFTED["~"] = "`"

# --- named keys (reserved words) -> XKB name ---------------------------------
NAMED = {
    "enter": "RTRN", "return": "RTRN", "tab": "TAB", "space": "SPCE",
    "backspace": "BKSP", "esc": "ESC", "shift": "LFSH", "ctrl": "LCTL",
    "alt": "LALT", "caps": "CAPS",
    "up": "UP", "down": "DOWN", "left": "LEFT", "right": "RGHT",
    "home": "HOME", "end": "END", "pageup": "PGUP", "pagedown": "PGDN",
    "pgup": "PGUP", "pgdn": "PGDN", "insert": "INS", "delete": "DELE",
}
for _i in range(1, 13):
    NAMED[f"f{_i}"] = f"FK{_i:02d}"

_RAW = re.compile(r"^0[xX][0-9a-fA-F]+$")

def _scan(xkb_name):
    if xkb_name not in XKB:
        sys.exit(f"keymap: no scancode for XKB name '{xkb_name}'")
    return XKB[xkb_name]

def _events_for_char(ch, action="tap"):
    """Ordered (scan, down) events for one literal character."""
    if ch in CHAR:
        name, upper = CHAR[ch], False
    elif ch in SHIFTED:
        name, upper = CHAR[SHIFTED[ch]], True
    else:
        lo = ch.lower()
        if lo in CHAR:
            name, upper = CHAR[lo], True
        else:
            sys.exit(f"keymap: no scancode for character {ch!r}")
    code = _scan(name)
    if upper:
        ev = [(SHIFT, 1), (code, 1), (code, 0), (SHIFT, 0)]
    else:
        ev = [(code, 1), (code, 0)]
    # down/up keep only the make (break) side, modifier pairing intact.
    if action == "down":
        return [(c, d) for c, d in ev if d]
    if action == "up":
        return [(c, d) for c, d in ev if not d]
    return ev

def _events_for_key(token, action):
    """Ordered (scan, down) events for one KEY token under the given action."""
    if not token:
        return []
    keep_down = action in ("tap", "down")
    keep_up   = action in ("tap", "up")

    # literal run of characters (not a raw code, not a named key)
    if not _RAW.match(token) and token.lower() not in NAMED and len(token) > 1:
        ev = []
        for ch in token:
            ev.extend(_events_for_char(ch))
        return ev

    if _RAW.match(token):
        code = int(token, 16)
    elif token.lower() in NAMED:
        code = _scan(NAMED[token.lower()])
    else:  # exactly one literal character
        return _events_for_char(token, action)

    ev = []
    if keep_down:
        ev.append((code, 1))
    if keep_up:
        ev.append((code, 0))
    return ev

def _emit(events):
    i = 0
    while i < len(events):
        down = events[i][1]
        codes = []
        while i < len(events) and events[i][1] == down:
            codes.append(f"0x{events[i][0]:x}")
            i += 1
        print(f"{'down' if down else 'up'} {' '.join(codes)}")

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("tap", "down", "up"):
        sys.exit("keymap: usage: keymap.py <tap|down|up> KEY...")
    ev = []
    for token in sys.argv[2:]:
        ev.extend(_events_for_key(token, sys.argv[1]))
    _emit(ev)
