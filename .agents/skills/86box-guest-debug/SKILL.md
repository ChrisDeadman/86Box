name: 86box-guest-debug
description: Debug the guest x86 program (registers, memory, screen, run-until-state) through the automation socket. No special build; host process debugging is 86box-debug-attach.
---

# Guest Debug 86Box

Inspect and drive the **guest** through the automation socket (`vm.sh`,
`box.sh` from the `86box-automation` skill). Standard build, no gdbserver, no
attach race. Host-side process debugging belongs to `86box-debug-attach`.

## Recipe

```bash
S=.agents/skills/86box-automation/scripts
$S/vm.sh --vm-dir $VM start --cfg 86box_minimal.cfg --hold   # frozen at reset vector
$S/box.sh --vm-dir $VM regs                                  # guest state
$S/box.sh --vm-dir $VM step 8000                             # run 8 s emulated
$S/box.sh --vm-dir $VM text rows                             # decoded text screen
$S/box.sh --vm-dir $VM memr 0x449 2                          # physical memory
$S/box.sh --vm-dir $VM memw <addr> <hex>
$S/box.sh --vm-dir $VM wait-mem 10000 0x449 03               # run until memory state
$S/box.sh --vm-dir $VM shot /abs/frame.png                   # graphics mode
```

- `--hold` starts the guest frozen at the reset vector (`eip=0xffe0`),
  before any POST code runs. Nothing advances until you ask.
- `regs`: `eax`-`edi`, `eip`, `eflags`, segment selectors, `cs_base`, `cr0`
  (decimal; `eip` is the linear guest instruction pointer).
- `step <ms>`: run exactly that much emulated time, then hold again.
- `text rows`: CP437 text screen, blank rows dropped, cursor shown. Text
  modes only; use `shot` in graphics mode.
- `memr`/`memw`: physical addresses. Reading memory-mapped device ranges can
  have side effects (VGA latches).
- `wait-text`/`wait-mem`: run until a screen row or memory value matches; the
  memory form is a watchpoint.
- `key`/`mouse` drive the guest; see `86box-automation` for scancodes.
- `status` includes `bios_mode` (BIOS data area 0x449) as a cheap boot-phase
  indicator.

## Debugging loop

1. Start `--hold`, boot to the point of interest with `step`/`wait-mem`.
2. Freeze, read `regs` + `text rows` (or `memr` the relevant structure).
3. `memw` to test a hypothesis, `step`, re-read. Deterministic: repeat the
   same sequence and the guest lands in the same state.
4. Stop: `quit` (no writable guest disk) or `quit-soft` (real VM).

## Limits

- The socket stops only at frame boundaries (1 emulated ms ~ hundreds of
  guest instructions): no hard breakpoints, no single-step, and an EIP held
  for a fraction of a frame is missed. For the guest work we do, `wait-mem`
  / `wait-text` (stop on a memory value or screen row) cover it.
- **Do not reach for the guest gdbstub.** A hard breakpoint / single-step
  needs the in-loop stop check only a `GDBSTUB=ON` build has, but it costs a
  per-instruction check in the exec loop and a finicky single-client gdbserver
  port, and every past use produced measurement artifacts (paused-at-
  `0xfffffff0` misread as a reboot, a bare TCP probe wedging the stub,
  one-packet-per-frame scan throughput). If a case genuinely needs to stop
  mid-frame, say so and decide deliberately rather than defaulting to a
  `GDBSTUB=ON` build.
- `step 1` is the smallest step unit (1 ms of emulated time, several guest
  instructions); it is not a single-step. Prefer waiting on a memory or
  screen state.
- `memw` does not invalidate compiled code blocks, so patching live guest code this
  way is unreliable; for a live code patch use GDB + `mem_write_ramb_page`
  (see `.scratch/archive/findings/live-guest-code-patching.md`).

## Related skills

- `86box-automation` - start/stop, key scancodes, protocol reference.
- `86box-debug-attach` - host process: backtraces, PIC, GDB attach.
