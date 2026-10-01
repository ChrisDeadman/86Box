name: 86box-profile
description: Profile a running 86Box with perf: hardware counters plus function-level sampling, written to .scratch/VM/profile
---

# Profile 86Box with perf

## Overview

Runs `perf stat` and `perf record` against a running 86Box process:
function-level call graphs, annotated hotspots, and summary reports.
Start the instance first with the `86box-automation` skill (vm.sh).

## When to Use

Use this skill when:
- Need to identify CPU hotspots in dynarec or emulation
- Looking for dispatch loop or flags_rebuild bottlenecks
- Need to track optimization impact over time
- Analyzing instruction-level behavior

## Command

```bash
scripts/perf.sh [seconds] [PID]
```

**Arguments:**
- First argument: duration in seconds (default: 20)
- Second argument: PID to profile (auto-detect if omitted)

## Output Files

All in `.scratch/VM/profile/<YYYY-MM-DD_HHMMSS>.*`:

| Suffix | Description |
|--------|-------------|
| `.stat` | Hardware counters (cycles, instructions, L1d/L1i misses, etc.) |
| `.txt` | Flat function-level report |
| `.callgraph.txt` | Full call graph with percentages |
| `.annotate.txt` | Hot function annotations (exec386_dynarec, flags_rebuild_*, etc.) |

## Auto-Detection

If no PID is given: prefer the scratch live instance
(`.scratch/VM/live/pid`), else the newest 86Box process. Errors if none found.

## Phase 1: Hardware Counters

```
perf stat -p <PID> -d -d --timeout <secs>
```

Captures:
- cycles, instructions, retired_instructions
- L1d_loads, L1d_misses, L1d_cache_lines
- L1i_loads, L1i_misses, branch_mispredictions
- And more (depends on CPU)

## Phase 2: Function Sampling

```
perf record --call-graph fp -F 499 -p <PID> -o data.data -- sleep <secs>
```

- FP call graph (fast-path)
- 499 Hz sample rate
- Function-level resolution

## Report Generation

```bash
perf report -i data.data --stdio --no-children --no-call-graph --percent-limit 0.3 -s sym,dso > txt.txt
perf report -i data.data --stdio --children --percent-limit 0.5 --call-graph callee,1,caller > callgraph.txt
```

## Known Hot Functions

- `exec386_dynarec` - Dynarec code generation
- `flags_rebuild_zpna` - ZPNA flag rebuilding
- `flags_rebuild_c` - Conditional flag rebuilding
- `mmutranslatereal` - MMU translation
- `CF_SET` - Carry flag setting

## Notes

- Do NOT ctrl+c during Phase 2; the data file will be corrupted
- Raw data is deleted after reports are generated to save space
- LTO-optimized build produces more accurate perf data
