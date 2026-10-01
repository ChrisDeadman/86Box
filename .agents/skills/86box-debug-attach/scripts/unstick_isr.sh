#!/usr/bin/env bash
# Unstick the PIC by clearing the ISR and setting IRR to pending.
# Usage: scripts/unstick_isr.sh [PID]
# Example: scripts/unstick_isr.sh 15752
set -euo pipefail
PID="${1:-}"
if [[ -z "$PID" ]]; then
  echo "Usage: $0 [PID]" >&2
  exit 1
fi

gdb -batch -ex "set pagination off" -ex "attach $PID" \
  -ex "set pic.isr = 0" \
  -ex "set pic.int_pending = 1" \
  -ex "printf 'Fixed: ISR=%02x IRR=%02x\\n', pic.isr, pic.irr" \
  -ex "detach" 2>&1 | grep -E "Fixed:|error"
