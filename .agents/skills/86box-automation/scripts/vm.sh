#!/usr/bin/env bash
# 86Box VM lifecycle: start / stop / status / pid / wait, headless (Xvfb + Qt).
# The automation socket is always on. Never kills a running instance.
# State for a purpose lives in <vm-dir>/<purpose>/: socket, pid, logs.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
BOX="$SCRIPT_DIR/box.sh"

VM_DIR="${VM_DIR:-}"
MODE="${RUN_86BOX_MODE:-qt-sw}"        # qt-sw (default), qt-gl, sdl-gl, sdl-sw
PURPOSE="${VM_PURPOSE:-live}"
BIN="${RUN_86BOX_BIN:-}"
CFG="${RUN_86BOX_CFG:-}"
AUTOMATION=1
AUTOMATION_ENDPOINT=""
STARTUP_TIMEOUT="${RUN_86BOX_STARTUP_TIMEOUT:-60}"

usage() {
  cat <<EOF
Usage: vm.sh --vm-dir PATH [--purpose DIR] <command> [options]

Commands:
  start --cfg PATH [--bin PATH] [--qt-sw|--qt-gl|--sdl-gl|--sdl-sw]
        [--hold] [--no-automation] [--timeout SECS] [--display N]
        Start a headless instance. --cfg is required and resolved against the
        VM dir (it must live there; 86Box resolves the cfg's relative disk
        paths against its directory). Refuses if one already runs for the
        purpose. Prints PID when ready.
  stop      Clean power-off: guest soft power-off (ACPI/device button) + wait for exit. Never kills.
  status    Forward to box.sh status (JSON)
  pid       Print the running PID, or exit 1
  wait [timeout_s]   Wait for the running instance to be ready

State for a purpose lives in <vm-dir>/<purpose>/: socket, pid, logs.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --vm-dir) VM_DIR="$2"; shift 2 ;;
    --purpose) PURPOSE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) break ;;
  esac
done

[[ -n "$VM_DIR" ]] || { echo "ERROR: --vm-dir PATH is required" >&2; usage >&2; exit 1; }
VM_DIR="$(cd "$VM_DIR" 2>/dev/null && pwd)" || { echo "ERROR: VM dir not found: $VM_DIR" >&2; exit 1; }
# Derive after parsing, so --purpose wins over VM_PURPOSE.
PURPOSE_DIR="$VM_DIR/$PURPOSE"
EMU_LOG="$PURPOSE_DIR/86box.log"
RUN_LOG="$PURPOSE_DIR/run.log"
PIDFILE="$PURPOSE_DIR/pid"
SOCKET="$PURPOSE_DIR/automation.sock"

[[ $# -ge 1 ]] || { usage >&2; exit 1; }
CMD="$1"; shift || true

case "$CMD" in
  start)
    ;;
  stop)
    exec "$BOX" --socket "$SOCKET" quit-soft
    ;;
  status)
    exec "$BOX" --socket "$SOCKET" status
    ;;
  pid)
    [[ -f "$PIDFILE" ]] || { echo "ERROR: no instance started for purpose '$PURPOSE'" >&2; exit 1; }
    pid=$(<"$PIDFILE")
    kill -0 "$pid" 2>/dev/null || { echo "ERROR: instance $pid not running" >&2; exit 1; }
    printf '%s\n' "$pid"
    ;;
  wait)
    exec "$BOX" --socket "$SOCKET" wait "${1:-60}"
    ;;
  *)
    echo "ERROR: unknown command: $CMD" >&2
    usage >&2
    exit 1
    ;;
esac

# ---- start ----

DISPLAY_NUM="${VM_DISPLAY:-99}"
START_HOLD=0

canonical_mode() {
  case "$1" in
    qt|qt-sw|qt-software)  printf 'qt-sw' ;;
    qt-gl|qt-opengl|qt-opengl3) printf 'qt-gl' ;;
    unix-osd|unix-osd-gl|sdl-gl|sdl-opengl) printf 'sdl-gl' ;;
    unix-osd-sw|unix-osd-software|sdl-sw|sdl-software) printf 'sdl-sw' ;;
    *) return 1 ;;
  esac
}

is_qt_mode() { [[ "$MODE" == qt-* ]]; }

set_default_bin() {
  [[ -n "$BIN" ]] && return 0
  case "$MODE" in
    qt-sw|qt-gl)  BIN="$REPO_ROOT/build/src/86Box" ;;
    sdl-gl)       BIN="$REPO_ROOT/build/unix-osd-build/src/86Box" ;;
    sdl-sw)       BIN="$REPO_ROOT/build/unix-osd-noshader-build/src/86Box" ;;
    *) echo "ERROR: unsupported run mode: $MODE" >&2; exit 1 ;;
  esac
}

# 86Box resolves the cfg's relative disk/NVR/media paths against the config's
# directory, so the config must live in the VM dir (same as the archive scripts).
set_default_cfg() {
  [[ -f "$CFG" ]] || { echo "ERROR: config not found: $CFG" >&2; exit 1; }
  [[ "$CFG" == "$VM_DIR"/* ]] || { echo "ERROR: config must be in the VM dir ($VM_DIR), got: $CFG" >&2; exit 1; }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --qt|--qt-sw) MODE="qt-sw"; shift ;;
    --qt-gl) MODE="qt-gl"; shift ;;
    --sdl-gl|--unix-osd) MODE="sdl-gl"; shift ;;
    --sdl-sw|--unix-osd-sw) MODE="sdl-sw"; shift ;;
    --bin) BIN="$2"; shift 2 ;;
    --cfg) CFG="$2"; shift 2 ;;
    --hold) START_HOLD=1; shift ;;
    --no-automation) AUTOMATION=0; shift ;;
    --automation) AUTOMATION_ENDPOINT="$2"; shift 2 ;;
    --timeout) STARTUP_TIMEOUT="$2"; shift 2 ;;
    --display) DISPLAY_NUM="$2"; shift ;;
    *) echo "ERROR: unknown option: $1" >&2; usage >&2; exit 1 ;;
  esac
done

# Pick the OS explicitly: no default config.
if [[ -z "$CFG" ]]; then
  echo "ERROR: --cfg is required. Configs in $VM_DIR:" >&2
  ( cd "$VM_DIR" && ls -1 *.cfg 2>/dev/null | sed 's/^/  --cfg /' ) >&2
  exit 1
fi
[[ "$CFG" == /* ]] || CFG="$VM_DIR/$CFG"

MODE=$(canonical_mode "$MODE") || { echo "ERROR: unsupported run mode: $MODE" >&2; exit 1; }
[[ "$STARTUP_TIMEOUT" =~ ^[0-9]+$ && "$STARTUP_TIMEOUT" -gt 0 ]] || {
  echo "ERROR: --timeout must be a positive integer" >&2; exit 1
}

# Refuse to start on top of a running instance: killing it risks a corrupt guest disk.
if [[ -f "$PIDFILE" ]]; then
  old=$(<"$PIDFILE")
  if kill -0 "$old" 2>/dev/null; then
    echo "ERROR: 86Box instance $old already runs for purpose '$PURPOSE'" >&2
    echo "Stop it first:  vm.sh --purpose $PURPOSE stop" >&2
    exit 1
  fi
fi

# Leftover socket from a crash: 86Box unlinks it at startup, but tell the user.
if [[ -S "$SOCKET" ]]; then
  echo "[vm] warning: stale socket $SOCKET (previous instance did not exit cleanly?)" >&2
fi
set_default_bin
[[ -x "$BIN" ]] || { echo "ERROR: binary not found or not executable: $BIN (run the 86box-build skill)" >&2; exit 1; }

mkdir -p "$PURPOSE_DIR"
set_default_cfg

# Xvfb for the Qt UI; automation works without a display, but the renderer
# wants one.
if ! pgrep -f "Xvfb :$DISPLAY_NUM" >/dev/null; then
  Xvfb ":$DISPLAY_NUM" -screen 0 1280x960x24 > "$PURPOSE_DIR/xvfb.log" 2>&1 &
  echo $! > "$PURPOSE_DIR/xvfb.pid"
  sleep 1
fi

# Mesa EGL vendor JSON: prints "json<TAB>lib"; a relative library_path is resolved via ldconfig.
find_egl_vendor() {
  local candidate egl_lib
  local -a existing=() roots=() candidates=()

  if [[ -n "${__EGL_VENDOR_LIBRARY_FILENAMES:-}" ]]; then
    IFS=: read -r -a existing <<< "$__EGL_VENDOR_LIBRARY_FILENAMES"
    for candidate in "${existing[@]}"; do
      [[ -f "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
    done
  fi
  for candidate in /run/opengl-driver /usr/share/glvnd; do
    [[ -d "$candidate" ]] && roots+=("$candidate")
  done
  mapfile -t candidates < <(find "${roots[@]}" -maxdepth 6 -path '*/egl_vendor.d/50_mesa.json' 2>/dev/null | sort)
  for candidate in "${candidates[@]}"; do
    case "$candidate" in *fhs*|*steam*|*lutris*|*heroic*|*Vial*) continue ;; esac
    egl_lib=$(sed -n 's/.*"library_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$candidate" | head -1)
    [[ -n "$egl_lib" ]] || continue
    if [[ "$egl_lib" != /* ]]; then
      egl_lib=$(ldconfig -p | awk -v lib="$egl_lib" '$1 == lib { sub(/.*=> /, ""); print; exit }')
    fi
    [[ -r "$egl_lib" ]] || continue
    printf '%s\t%s\n' "$candidate" "$egl_lib"
    return 0
  done
  return 1
}

if is_qt_mode; then
  egl_info=$(find_egl_vendor) || { echo "ERROR: could not find a usable Mesa EGL vendor JSON" >&2; exit 1; }
  egl_json=${egl_info%%$'\t'*}
  egl_lib=${egl_info##*$'\t'}
  mesa_lib_dir=$(dirname "$egl_lib")
  export __EGL_VENDOR_LIBRARY_FILENAMES="$egl_json"
  [[ -z "${LIBGL_DRIVERS_PATH:-}" && -d "$mesa_lib_dir/dri" ]] && export LIBGL_DRIVERS_PATH="$mesa_lib_dir/dri"
  [[ -z "${GBM_BACKENDS_PATH:-}" && -d "$mesa_lib_dir/gbm" ]] && export GBM_BACKENDS_PATH="$mesa_lib_dir/gbm"
  export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-xcb}"
  echo "[vm] EGL vendor: $egl_json ($egl_lib)"
  echo "[vm] QT_QPA_PLATFORM: $QT_QPA_PLATFORM"
fi

# Automation socket: the control channel and what makes a clean stop possible.
AUTOMATION_ARGS=()
if [[ $AUTOMATION -eq 1 ]]; then
  if [[ -n "$AUTOMATION_ENDPOINT" ]]; then
    AUTOMATION_ARGS=(--automation "$AUTOMATION_ENDPOINT")
  else
    AUTOMATION_ARGS=(--automation "unix:$SOCKET")
  fi
fi

args=(--logfile "$EMU_LOG")
if [[ $START_HOLD -eq 1 ]]; then
  args+=(--automation-hold)
fi

echo "[vm] mode: $MODE"
echo "[vm] binary: $BIN"
echo "[vm] config: $CFG"
echo "[vm] purpose dir: $PURPOSE_DIR"
[[ $AUTOMATION -eq 1 ]] && echo "[vm] automation: ${AUTOMATION_ARGS[*]:-unix:$SOCKET}"

# cd into the VM dir so the cfg's relative paths resolve.
cd "$VM_DIR"
if [[ $AUTOMATION -eq 1 ]]; then
  rm -f "$SOCKET"
  QT_QPA_PLATFORM=xcb DISPLAY=":$DISPLAY_NUM" \
    nohup "$BIN" "${AUTOMATION_ARGS[@]}" "${args[@]}" "$CFG" > "$RUN_LOG" 2>&1 < /dev/null &
else
  QT_QPA_PLATFORM=xcb DISPLAY=":$DISPLAY_NUM" \
    nohup "$BIN" "${args[@]}" "$CFG" > "$RUN_LOG" 2>&1 < /dev/null &
fi
pid=$!
printf '%s\n' "$pid" > "$PIDFILE"
echo "[vm] 86Box pid $pid"
echo "[vm] emulator log: $EMU_LOG"
echo "[vm] run log: $RUN_LOG"

# Ready when the socket answers status. With --hold it stays frozen until driven.
if [[ $AUTOMATION -eq 1 && -z "$AUTOMATION_ENDPOINT" ]]; then
  if ! "$BOX" --socket "$SOCKET" wait "$STARTUP_TIMEOUT"; then
    if kill -0 "$pid" 2>/dev/null; then
      echo "ERROR: socket not answering after ${STARTUP_TIMEOUT}s but $pid is alive." >&2
      echo "Do NOT kill it; inspect $RUN_LOG and $EMU_LOG, then ask the user." >&2
      exit 1
    fi
    echo "ERROR: 86Box exited during startup" >&2
    tail -40 "$RUN_LOG" >&2
    exit 1
  fi
fi

printf '%s\n' "$pid"
