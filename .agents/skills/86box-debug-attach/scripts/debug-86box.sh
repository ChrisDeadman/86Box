#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
TARGET_PID=""
MODE="summary"
SAMPLE_COUNT="5"
SAMPLE_DELAY="1"
TARGET_BIN="${DEBUG_86BOX_BIN:-$REPO_ROOT/build/src/86Box}"
GDB_SCRIPT=""
LOG_PATH=""

usage() {
    cat <<EOF
Attaches GDB to a running 86Box process. Host-side debugging only: backtraces,
PIC unsticking, live C debugging. Starting/stopping the VM is the
86box-automation skill's job (vm.sh / box.sh) - never kill 86Box here.

Usage:
    $0 [--pid PID] [--bin PATH] [summary|threads|bt|sample|maps|interactive|script|cmdfifo]

Modes:
  summary      info threads + all-thread backtraces (default)
  threads      info threads only
  bt           all-thread backtraces only
  sample       repeated all-thread backtrace sampling
  maps         print executable mappings for PIE resolution
  interactive  open an interactive local gdb attach session
  script       run a batch gdb script against the live process
  cmdfifo      run a batch gdb script for CMDFIFO capture (requires --script and --log)

Options:
  --pid PID        attach to this 86Box PID instead of the newest one
  --bin PATH       debugger binary with symbols (default: $REPO_ROOT/build/src/86Box)
  --samples N      sample count for sample mode (default: 5)
  --delay SEC      delay between sample captures (default: 1)
  --script PATH    gdb script for script/cmdfifo mode
  --log PATH       output path for script/cmdfifo mode
  -h, --help       show this help

Examples:
  $0 summary
  $0 interactive
  $0 --samples 8 --delay 0.5 sample
  $0 script --script path/to/script.gdb --log output.log
  $0 cmdfifo --script path/to/capture.gdb --log capture.log
EOF
}

find_newest_86box_pid() {
    local proc_path
    local newest_pid=""
    local newest_start=""
    local pid
    local start_ticks

    for proc_path in /proc/[0-9]*; do
        pid="${proc_path#/proc/}"
        [[ -r "/proc/$pid/stat" ]] || continue
        process_matches_86box "$pid" || continue
        start_ticks=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
        [[ "$start_ticks" =~ ^[0-9]+$ ]] || continue

        if [[ -z "$newest_start" || "$start_ticks" -gt "$newest_start" ]]; then
            newest_pid="$pid"
            newest_start="$start_ticks"
        fi
    done

    [[ -n "$newest_pid" ]] || return 1
    printf '%s\n' "$newest_pid"
}

process_matches_86box() {
    local pid="$1"
    local exe=""
    local target_bin=""
    local cmdline=""

    [[ -r "/proc/$pid/cmdline" ]] || return 1

    exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
    target_bin=$(readlink -f "$TARGET_BIN" 2>/dev/null || true)
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)

    if [[ -n "$target_bin" && -n "$exe" && "$exe" == "$target_bin" ]]; then
        return 0
    fi

    if [[ -n "$exe" && "$(basename "$exe")" == "86Box" ]]; then
        return 0
    fi

    case "$cmdline" in
        86Box\ *|*/86Box\ *) return 0 ;;
    esac

    return 1
}

validate_target_pid() {
    local pid="$1"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 2
    [[ -d "/proc/$pid" ]] || return 3
    [[ -r "/proc/$pid/cmdline" ]] || return 4
    process_matches_86box "$pid"
}

resolve_gdb_binary() {
    local pid="$1"

    if [[ -x "$TARGET_BIN" ]]; then
        printf '%s\n' "$TARGET_BIN"
    else
        readlink -f "/proc/$pid/exe"
    fi
}

describe_target() {
    local pid="$1"
    local bin="$2"
    local cwd cmdline

    cwd=$(readlink -f "/proc/$pid/cwd" 2>/dev/null || echo unknown)
    cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo unknown)

    echo "Attaching to 86Box PID $pid"
    echo "  cwd: $cwd"
    echo "  cmd: $cmdline"
    echo "  gdb-bin: $bin"
}

run_batch_gdb() {
    local pid="$1"
    local bin="$2"
    shift 2
    local -a args

    args=(gdb -q "$bin" -batch
        -ex "set pagination off"
        -ex "set confirm off"
        -ex "set print thread-events off")

    while [[ $# -gt 0 ]]; do
        args+=(-ex "$1")
        shift
    done

    args+=(-p "$pid")
    "${args[@]}"
}

run_sample_mode() {
    local pid="$1"
    local bin="$2"
    local index=1

    while [[ "$index" -le "$SAMPLE_COUNT" ]]; do
        printf '===== sample %d/%d =====\n' "$index" "$SAMPLE_COUNT"
        run_batch_gdb "$pid" "$bin" "thread apply all bt" "detach" "quit"
        if [[ "$index" -lt "$SAMPLE_COUNT" ]]; then
            sleep "$SAMPLE_DELAY"
        fi
        index=$((index + 1))
    done
}

show_exec_maps() {
    local pid="$1"
    local exe

    exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
    [[ -n "$exe" ]] || {
        echo "ERROR: could not resolve /proc/$pid/exe"
        exit 1
    }

    echo "Executable: $exe"
    echo "Mappings:"
    awk -v exe="$exe" '$NF == exe { print }' "/proc/$pid/maps"
}

run_script_mode() {
    local pid="$1"
    local bin="$2"
    local script_path="$3"
    local log_path="$4"
    local effective_script="$script_path"
    local temp_script=""

    [[ -f "$script_path" ]] || {
        echo "ERROR: gdb script not found: $script_path"
        exit 1
    }

    if grep -q 'PID_PLACEHOLDER\|BINARY_PLACEHOLDER' "$script_path"; then
        temp_script=$(mktemp "$SCRIPT_DIR/debug-86box.XXXXXX.gdb")
        sed \
            -e "s|PID_PLACEHOLDER|$pid|g" \
            -e "s|BINARY_PLACEHOLDER|$bin|g" \
            "$script_path" > "$temp_script"
        effective_script="$temp_script"
    fi

    if [[ -n "$log_path" ]]; then
        gdb -batch -x "$effective_script" > "$log_path" 2>&1
        echo "Saved gdb log to $log_path"
    else
        gdb -batch -x "$effective_script"
    fi

    if [[ -n "$temp_script" && -f "$temp_script" ]]; then
        rm -f "$temp_script"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pid)
            [[ $# -ge 2 ]] || { echo "ERROR: --pid requires a value"; exit 1; }
            TARGET_PID="$2"
            shift 2
            ;;
        --bin)
            [[ $# -ge 2 ]] || { echo "ERROR: --bin requires a value"; exit 1; }
            TARGET_BIN="$2"
            shift 2
            ;;
        --samples)
            [[ $# -ge 2 ]] || { echo "ERROR: --samples requires a value"; exit 1; }
            SAMPLE_COUNT="$2"
            shift 2
            ;;
        --delay)
            [[ $# -ge 2 ]] || { echo "ERROR: --delay requires a value"; exit 1; }
            SAMPLE_DELAY="$2"
            shift 2
            ;;
        --script)
            [[ $# -ge 2 ]] || { echo "ERROR: --script requires a value"; exit 1; }
            GDB_SCRIPT="$2"
            shift 2
            ;;
        --log)
            [[ $# -ge 2 ]] || { echo "ERROR: --log requires a value"; exit 1; }
            LOG_PATH="$2"
            shift 2
            ;;
        summary|threads|bt|sample|maps|interactive|script|cmdfifo)
            MODE="$1"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$TARGET_PID" ]]; then
    TARGET_PID=$(find_newest_86box_pid) || {
        echo "ERROR: no running 86Box process found"
        exit 1
    }
fi

validate_target_pid "$TARGET_PID" || {
    case "$?" in
        2) echo "ERROR: PID must be numeric" ;;
        3) echo "ERROR: PID $TARGET_PID is not running" ;;
        4) echo "ERROR: PID $TARGET_PID is not an 86Box process" ;;
        *) echo "ERROR: failed to validate PID $TARGET_PID" ;;
    esac
    exit 1
}

TARGET_BIN=$(resolve_gdb_binary "$TARGET_PID")
describe_target "$TARGET_PID" "$TARGET_BIN"
echo ""

case "$MODE" in
    summary)
        run_batch_gdb "$TARGET_PID" "$TARGET_BIN" "info threads" "thread apply all bt" "detach" "quit"
        ;;
    threads)
        run_batch_gdb "$TARGET_PID" "$TARGET_BIN" "info threads" "detach" "quit"
        ;;
    bt)
        run_batch_gdb "$TARGET_PID" "$TARGET_BIN" "thread apply all bt" "detach" "quit"
        ;;
    sample)
        run_sample_mode "$TARGET_PID" "$TARGET_BIN"
        ;;
    maps)
        show_exec_maps "$TARGET_PID"
        ;;
    interactive)
        exec gdb -q "$TARGET_BIN" -p "$TARGET_PID"
        ;;
    script)
        [[ -n "$GDB_SCRIPT" ]] || {
            echo "ERROR: script mode requires --script PATH"
            exit 1
        }
        run_script_mode "$TARGET_PID" "$TARGET_BIN" "$GDB_SCRIPT" "$LOG_PATH"
        ;;
    cmdfifo)
        [[ -n "$GDB_SCRIPT" ]] || {
            echo "ERROR: cmdfifo mode requires --script PATH"
            exit 1
        }
        [[ -n "$LOG_PATH" ]] || {
            echo "ERROR: cmdfifo mode requires --log PATH"
            exit 1
        }
        run_script_mode "$TARGET_PID" "$TARGET_BIN" "$GDB_SCRIPT" "$LOG_PATH"
        ;;
esac
