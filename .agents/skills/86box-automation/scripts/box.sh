#!/usr/bin/env bash
# 86Box automation socket client: one request in, one JSON line out.
# Protocol: doc/specifications/automation.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

SOCKET="${BOX_SOCKET:-}"
VM_DIR="${BOX_VM_DIR:-}"
PURPOSE="${BOX_PURPOSE:-live}"
TIMEOUT="${BOX_TIMEOUT:-120}"
PIDFILE=""

usage() {
  cat <<EOF
Usage: box.sh [--vm-dir PATH] [--purpose DIR] [--socket PATH]
              [--timeout SECS] [--pidfile PATH] <command> [args...]

Commands (protocol: doc/specifications/automation.md):
  status | info | regs
  text [rows]                        text screen; rows = decoded CP437 rows
  hold | release
  ff [on|off]                        fast forward (no real-time pacing); no arg = query
  step <ms>
  wait-text <timeout_ms> <text...>    run until <text> appears in a text-screen row
  wait-mem <timeout_ms> <addr> <hex>
  shot [path]                          screenshot (default: <socket dir>/shot.png)
  record-start <interval_ms> <dir> | record-stop
  key <down|up|tap> <scancodes...>     set-1 codes, 0x100+code = E0 prefix (0x148 = Up)
  mouse <dx> <dy> <buttons>
  memr <addr> <len> | memw <addr> <hex>
  fdd <load|eject> <drive> [path] | cd <load|eject> <drive> [path]
  reset <hard|cad>
  quit-soft                          clean guest power-off (ACPI/device power button), waits for exit
  quit [soft]                        host-side power-off, fast, guest does not shut down
  wait [timeout_s]                     wait until the socket answers status

Options:
  --socket PATH    socket path (wins over --vm-dir/--purpose and BOX_SOCKET)
  --vm-dir PATH    derive the socket: <vm-dir>/<purpose>/automation.sock
  --purpose DIR    purpose directory (default: live)
  --timeout SECS   per-request wall timeout (default 120)
  --pidfile PATH   pid written by vm.sh (default: <socket dir>/pid); used to wait for exit
EOF
}

# $1 = request, $2 = wall seconds to keep retrying a refused connection
# (0 = fail fast). The automation server does not accept connections while
# the main loop is busy in early BIOS init, so the "run until" commands
# (wait text/mem) retry; action commands fail fast on a dead instance.
ask() {
  python3 - "$SOCKET" "$1" "$TIMEOUT" "${2:-0}" <<'PY'
import socket, sys, time

path, req, timeout, retry = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
deadline = time.monotonic() + retry
while True:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(path)
        break
    except (ConnectionRefusedError, FileNotFoundError):
        if time.monotonic() >= deadline:
            sys.stderr.write(f"ERROR: no 86Box instance answering on {path} "
                             f"(not running, or not accepting during boot)\n")
            sys.exit(2)
        time.sleep(0.5)
s.sendall(req.encode() + b"\n")
buf = b""
while not buf.endswith(b"\n"):
    n = s.recv(65536)
    if not n:
        break
    buf += n
sys.stdout.write(buf.decode(errors="replace"))
PY
}

wait_for_socket() {
  local timeout="${1:-60}" end=$SECONDS
  while ! ask status >/dev/null 2>&1; do
    if (( SECONDS - end >= timeout )); then
      echo "ERROR: socket $SOCKET not answering within ${timeout}s" >&2
      return 1
    fi
    sleep 0.5
  done
}

resolve_pidfile() {
  if [[ -z "$PIDFILE" ]]; then
    PIDFILE="$(dirname "$SOCKET")/pid"
  fi
  [[ -f "$PIDFILE" ]] || {
    echo "ERROR: pidfile not found: $PIDFILE (start via vm.sh, or pass --pidfile)" >&2
    exit 1
  }
}

# Wait up to $2 seconds for the instance to stop: the pidfile pid is gone
# and the socket stops answering. Either check alone can lie: a stale
# pidfile (hand-started instance) reports early, and so does a socket that
# closes while the process is still syncing.
wait_for_exit() {
  local pidfile="$1" timeout="$2" pid end=$SECONDS alive
  pid=$(<"$pidfile")
  while :; do
    alive=0
    if kill -0 "$pid" 2>/dev/null; then
      alive=1
    elif TIMEOUT=5 ask status >/dev/null 2>&1; then
      alive=1
    fi
    if (( ! alive )); then
      return 0
    fi
    if (( SECONDS - end >= timeout )); then
      return 1
    fi
    sleep 1
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --socket)  SOCKET="$2"; shift 2 ;;
    --vm-dir)  VM_DIR="$2"; shift 2 ;;
    --purpose) PURPOSE="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --pidfile) PIDFILE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) break ;;
  esac
done

# --socket wins; otherwise derive the socket from the VM dir and purpose.
if [[ -z "$SOCKET" ]]; then
  if [[ -n "$VM_DIR" ]]; then
    SOCKET="$VM_DIR/$PURPOSE/automation.sock"
  else
    echo "ERROR: no socket: pass --socket PATH or --vm-dir PATH (or BOX_SOCKET)" >&2
    exit 1
  fi
fi

[[ $# -ge 1 ]] || { usage >&2; exit 1; }
CMD="$1"; shift || true

case "$CMD" in
  wait)
    wait_for_socket "${1:-60}"
    ask status
    ;;
  status|info|regs|hold|release)
    ask "$CMD"
    ;;
  text)
    if [[ "${1:-}" == rows ]]; then
      ask text | python3 -c 'import json,sys; d=json.load(sys.stdin); print("cursor", d.get("cursor")); [print(i, bytes.fromhex(r).decode("cp437","replace").rstrip()) for i,r in enumerate(d.get("chars",[])) if any(b not in (0x00, 0x20) for b in bytes.fromhex(r))]'
    else
      ask text
    fi
    ;;
  ff)
    ask "ff $*"
    ;;
  step)
    ask "step $*"
    ;;
  wait-text)
    # wait text <timeout_ms> <rest of line>; retry refused connections
    # for the full per-request wall timeout (boot can outlast a status ping)
    ask "wait text $*" "$TIMEOUT"
    ;;
  wait-mem)
    ask "wait mem $*" "$TIMEOUT"
    ;;
  shot)
    ask "screenshot ${1:-$(dirname "$SOCKET")/shot.png}"
    ;;
  record-start|record-stop)
    ask "record $*"
    ;;
  key)
    action="$1"; shift
    # Keys are strings (a, A, "cd blood", Enter, 0xNN). keymap.py resolves each
    # to 86Box scancode events (values parsed from 86Box's own keymap source).
    map_out="$(python3 "$SCRIPT_DIR/keymap.py" "$action" "$@" 2>&1)" \
      || { echo "key: $map_out" >&2; exit 1; }
    [[ -n "$map_out" ]] || exit 0
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      dir="${line%% *}"; codes="${line#* }"
      ask "key $dir $codes"
    done <<< "$map_out"
    ;;
  mouse)
    ask "mouse $*"
    ;;
  memr|memw)
    ask "$CMD $*"
    ;;
  fdd|cd)
    ask "$CMD $*"
    ;;
  reset)
    ask "reset $*"
    ;;
  quit-soft)
    # GUI "Power off (soft)" cascade; guest must run its shutdown, so refuse when held.
    resolve_pidfile
    st=$(ask status)
    if grep -q '"held":true' <<<"$st"; then
      echo "ERROR: machine is held; emulated time is frozen so the guest cannot power off. 'release' first (vm.sh stop does this automatically)." >&2
      exit 1
    fi
    ask "quit soft"
    if wait_for_exit "$PIDFILE" 90; then
      echo "[box] instance shut down cleanly"
    else
      echo "ERROR: guest did not exit within 90s. It is still running: do NOT kill it, ask the user." >&2
      exit 2
    fi
    ;;
  quit)
    # Fast stop: host-side sync only, the guest does not shut down. 'quit soft' = quit-soft.
    if [[ "${1:-}" == "soft" ]]; then
      exec "$0" --socket "$SOCKET" --pidfile "${PIDFILE:-$(dirname "$SOCKET")/pid}" quit-soft
    fi
    resolve_pidfile
    ask quit
    if wait_for_exit "$PIDFILE" 20; then
      echo "[box] instance exited"
    else
      echo "ERROR: process did not exit within 20s; ask the user." >&2
      exit 2
    fi
    ;;
  *)
    echo "ERROR: unknown command: $CMD" >&2
    usage >&2
    exit 1
    ;;
esac
