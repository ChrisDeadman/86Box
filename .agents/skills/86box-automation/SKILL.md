name: 86box-automation
description: Start, drive, and stop headless 86Box instances via the automation socket. Use for any task that launches or interacts with a VM.
---

# 86Box Automation

Control headless 86Box instances through the automation control socket
(protocol: `doc/specifications/automation.md`).

The VM directory (config, disk images, media) is always passed explicitly
with `--vm-dir`.

## Verification rules

The machine reports what it is; it does not confirm what you intended.
Treat every action as failed until you observe otherwise.

- **No unverified action.** After each key, swap, media change, or restart,
  read the actual state and confirm the expected result before the next step.
- **No unconfirmed conclusion.** "Frozen", "working", "root cause" only after
  you have confirmed the machine is in the intended state (e.g. actually at the
  target screen, not sitting at a prompt).
- **Ground truth** is `text rows` (decoded console text + cursor; text modes),
  `screenshot` (graphics), and `regs` (`pe` = `cr0&1`, EIP width). Cross-check
  them; use `screenshot` for anything visual. A black 3D shot is not "no
  render" (see Behavior notes).
- **Bounded waits.** Drive with `wait-text <ms> "<expected>"` / `step <ms>`;
  never blind-sleep and guess.
- **One variable at a time.** An A/B changes exactly one thing (OVL, dynarec,
  Voodoo) between runs, with an identical, verified launch.

## Disk safety (read first)

**Never stop 86Box by killing the process or closing its window while the VM
runs** (`kill`, `kill -9`, `pkill`, SIGTERM, `xdotool windowclose`). Guest
writes in flight are lost; Windows guests then run a slow CHKDSK on the next
boot and the image can end up corrupt.

- **Win98 guests:** a hard stop is not acceptable; `quit-soft` is the normal
  stop. **MS-DOS guests:** `quit-soft` is a no-op (it only presses the ACPI
  power button, which DOS never reacts to), so `quit` is the stop. A hard
  stop is allowed (no journaling, no automatic repair: an interrupted write
  can leave a corrupt FAT that surfaces as DOS I/O errors).

Instances the skills start have the automation socket on by default, which
makes a socket-driven stop the normal path:

- Clean stop = `vm.sh stop` (or `box.sh quit-soft`): presses the emulated ACPI
  power button if the machine has ACPI, else the device power button, else
  hard power-off. One-shot, no fallback, and it only works if the guest OS
  handles the power button (Windows does, DOS does not). Refused when held;
  up to ~60s.
- Fast stop = `box.sh quit` (host-side power-off; the guest does not shut
  down). The only stop that works for MS-DOS guests; normal for disposable
  configs.
- Fallback when an instance was started *without* the socket: host-gdb soft
  power-off, flipping the same global the GUI "Power off (soft)" button flips
  (qt_mainwindow.cpp):
  `gdb -batch -ex "set pagination off" -ex "attach <pid>" -ex "set acpi_pwrbut_pressed = 1" -ex "detach" -ex "quit"`
  then wait up to ~60s for the process to exit on its own. For a Win98 guest
  where the soft power-off does not take: `kill -TERM <pid>` (never `-9`).
- If a stop does not work: leave the instance running and ask the user.
- If a guest was stopped uncleanly anyway, repair it before further work:
  boot it, let Windows finish its CHKDSK, then stop it cleanly. Do not paper over
  the longer boot with bigger script timeouts.

## Commands

```bash
S=.agents/skills/86box-automation/scripts
VM=<vm-dir> # e.g. .scratch/VM

$S/vm.sh --vm-dir $VM start --cfg 86box_win98.cfg       # headless, Qt software, Xvfb; prints PID
$S/vm.sh --vm-dir $VM start --cfg 86box_dos.cfg         # other OS: 86box_dos.cfg, 86box_minimal.cfg
$S/vm.sh --vm-dir $VM start --cfg 86box_dos.cfg --hold  # emulated time frozen until driven
$S/vm.sh --vm-dir $VM --purpose <d> start --cfg ...     # state dir: <vm-dir>/<d>/
$S/vm.sh --vm-dir $VM status                            # JSON status
$S/vm.sh --vm-dir $VM stop                              # clean power-off, waits for exit
$S/vm.sh --vm-dir $VM pid                               # PID of the running instance

$S/box.sh --vm-dir $VM status|info|text|regs
$S/box.sh --vm-dir $VM hold | release
$S/box.sh --vm-dir $VM ff [on|off]                  # fast forward; no arg = query
$S/box.sh --vm-dir $VM step 5000                    # run 5 s of emulated time
$S/box.sh --vm-dir $VM wait-text 40000 "c:\games>"  # boot until the DOS prompt
$S/box.sh --vm-dir $VM shot /abs/path/frame.png     # screenshot (absolute path!)
$S/box.sh --vm-dir $VM key tap "cd blood" "Enter"   # type a string, then Enter
$S/box.sh --vm-dir $VM key tap "Up"                 # a named key (raw 0xNN works too)
$S/box.sh --vm-dir $VM memr 0x400 16                # physical memory
$S/box.sh --vm-dir $VM record-start 1000 <project-dir>/rec ... && $S/box.sh --vm-dir $VM record-stop
$S/box.sh --vm-dir $VM quit-soft                    # clean stop (same as vm.sh stop)
$S/box.sh --vm-dir $VM quit                         # fast stop; the only stop that works for MS-DOS
```

`--socket PATH` (or `BOX_SOCKET`) overrides the derived socket on both
scripts; `--purpose <d>` targets a different state dir.

## State layout

`<vm-dir>/<purpose>/`: `automation.sock`, `pid`, `86box.log` (emulator),
`run.log` (stdout/err), `xvfb.log`, screenshots. Config and disks stay in the
VM dir; the purpose dir is runtime state only. Purposes in use: `live/` (main),
`repair/`, `debug/`, `profile/`.

## Behavior notes

- `vm.sh start` **refuses** when an instance already runs for that purpose
  (prints the PID and how to stop it). It never kills anything.
- Readiness = the socket answers `status`. With `--hold`, the machine stays
  frozen until you drive it with `step`/`wait-text`/`key`/`release`; emulated
  time only passes then. A `key` briefly unholds to deliver its events, so it
  advances time on its own even while held.
- `ff on` runs as fast as the host allows (no real-time pacing); it only
  matters while the machine is not held, and `step`/`wait-text` are unaffected.
- The automation server does not accept socket connections while the main
  loop is busy in early BIOS init (heavy PnP); readiness at start does not
  imply continuous availability. `wait-text`/`wait-mem` retry refused
  connections for the per-request wall timeout; other commands fail fast, so
  use `box.sh wait <s>` after `vm.sh start` before action commands.

- `wait text` matches raw text-screen bytes (CP437, case-sensitive); use the
  exact string. `text rows` decodes them; plain `text` is one hex row per line
  (format: doc/specifications/automation.md).
- `shot`/`record` write on the emulator's filesystem with the path given:
  pass absolute paths.
- `shot` can come back **all-black for 3D/Voodoo content** in 32-bit SVGA
  modes even when the guest is rendering fine (it is reliable for text
  screens). Do not treat a black 3D screenshot as "no render": confirm with
  the OVL trace tags / error text via `text rows`, or read the guest
  framebuffer via `memr` (chunked, MEM_MAX 64 KB per read).
- The guest log line `Illegal instruction 00008B55 (FF)` is a Win98 boot
  quirk; ignore it.
- `wait-text <ms>` is emulated time, but every socket request also has a
  host-side wall timeout (default 120 s; `--timeout`): requesting more raises
  a raw client `TimeoutError` that looks like a crash. Loop shorter waits or
  raise `--timeout`.
- 86Box can die with no crash line in `run.log`/`86box.log` (the
  `GLib-GObject-CRITICAL` startup noise is harmless). Socket reset or dead
  `vm.sh pid`, no crash line: just `vm.sh start` again.
- Don't hand-launch the 86Box binary from inside `.scratch/VM` with a
  repo-relative path: `.scratch` is a symlink chain, `..` won't resolve to the
  repo root (`vm.sh start` already tees stderr into `run.log`).

## Keys

`key` takes **key strings**, not raw scancodes (a raw `0xNN` still passes
through): each argument is a named key or a literal run of characters:

```bash
$S/box.sh --vm-dir $VM key tap "cd blood" "Enter"  # type text, then Enter
$S/box.sh --vm-dir $VM key tap "A" " " "B"          # uppercase + space
$S/box.sh --vm-dir $VM key tap "D:" "Enter"         # shifted ':' (shift auto-held)
```

- `"cd blood"` types c,d,space,b,l,o,o,d. Uppercase letters and shifted
  punctuation take a left-Shift around them automatically.
- Named keys: `enter`, `tab`, `space`, `backspace`, `esc`, `shift`, `ctrl`,
  `alt`, `caps`, `f1`-`f12`, `up`, `down`, `left`, `right`, `home`, `end`,
  `pageup`, `pagedown`, `insert`, `delete`.
- `key down` / `key up` hold and release any key (not just modifiers: `key down W`
  later `key up W`; a shifted character keeps its Shift pairing).
- Scancode values are parsed at runtime by `scripts/keymap.py` from 86Box's own
  keymap (`src/qt/xkbcommon_keyboard.cpp`), never hand-typed. This code space
  is not plain set-1: space is `0x39` (not `0x00`), backspace is `0x0e`.
- Events are 2 ms apart; one `key tap` per word is fine. Works held or running.
- **Verify every key action with `text rows`** (or `screenshot` for graphics)
  before moving on.

## Related skills

- `86box-build` - build the binary this skill runs.
- `86box-debug-attach` - host-side GDB (backtraces, PIC state); can start a
  fresh instance under a purpose via this skill.
- `86box-guest-debug` - debug the guest program (regs, memory, screen, run-until-state) with this socket.
- `86box-profile` - perf profiling of a running instance.
