name: 86box-debug-attach
description: Attach GDB to a running 86Box process for backtraces, PIC inspection, and live C debugging. Host-side only; VM lifecycle belongs to 86box-automation.
---

# Debug Attach 86Box

GDB attach to a **running** 86Box process: backtraces, thread state,
device struct inspection, live patching. This is host-side debugging only.

**Division of labor:**
- VM start/stop, keys, screenshots, waiting: `86box-automation` (`vm.sh`, `box.sh`).
- Debugging the guest program (registers, memory, screen, run-until-state):
  `86box-guest-debug` - same automation socket, no GDB.
- This skill never kills 86Box. A stale instance is an error to report; to (re)start, use `vm.sh --vm-dir <vm-dir> --purpose debug start` first.

## When to Use

- 86Box is running and needs live debugging or backtraces (hang, crash, misbehavior)
- Inspect guest-facing device state (`pic`, `keyboard`, etc.)
- Capture periodic backtrace snapshots of an intermittent issue
- PIC is stuck and the guest no longer gets interrupts

## Common Commands

### Quick Attach (threads + backtraces)

```bash
.agents/skills/86box-debug-attach/scripts/debug-86box.sh summary
```

Attaches to the newest 86Box PID, prints thread list + all-thread
backtraces, detaches. `--pid PID` targets a specific instance; `--bin PATH`
overrides the symbols binary (default `build/src/86Box`).

### Modes

- `threads` - thread list only
- `bt` - backtraces only
- `maps` - executable mappings (PIE address resolution)
- `--samples N --delay SEC sample` - repeated backtraces
- `interactive` - full GDB session
- `script --script x.gdb [--log out]` - batch GDB script; supports
  `PID_PLACEHOLDER` / `BINARY_PLACEHOLDER` templating
- `cmdfifo --script x.gdb --log out` - same, both flags required

### Inside an Interactive Session

Useful live expressions (verify against the current source before relying on them):

```
printf "PIC ISR: %02x IRR: %02x\n", pic.isr, pic.irr
set pic.isr = 0; set pic.int_pending = 1      # unstick PIC
call (void)keyboard_input(1, 0x1c)            # key down (make code)
call (void)keyboard_input(0, 0x1c)            # key up
```

`keyboard_input(down, scan_code)` mirrors what the automation socket does;
prefer `box.sh key` when the socket is available (no GDB pause involved).

## PIC Unsticking

If the guest hangs with the PIC stuck (ISR non-zero, IRR not progressing):

```bash
.agents/skills/86box-debug-attach/scripts/unstick_isr.sh <PID>
```

Prints `Fixed: ISR=00 IRR=XX`. This is a last resort for a wedged VM; with
the automation socket, drive the guest to a clean state first.

## Notes

- All modes detach and exit except `interactive`
- Attaching pauses the process briefly; a running VM resumes on detach
- GDB symbols come from the binary built by the `86box-build` skill
- Live guest code patching: never set `pages[].dirty_mask` by hand. Write through
  `mem_write_ramb_page(phys, value, &pages[phys >> 12])` so dirty-mask and
  evict-list bookkeeping stay consistent (a hand poke kills 86Box).
