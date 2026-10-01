name: 86box-build
description: Build 86Box (Qt or SDL frontends) with the canonical local build script. Use before running, profiling, or debugging a new binary.
---

# Build 86Box

```bash
.agents/skills/86box-build/scripts/build.sh [mode] [options]
```

Incremental by default; `--clean` for a full reconfigure.

| Mode | Build dir | Notes |
|---|---|---|
| `--qt` (default) | `build/` | Qt6, software + GL3 shader renderers |
| `--sdl-gl` | `build/unix-osd-build/` | SDL OSD with shaders |
| `--sdl-sw` | `build/unix-osd-noshader-build/` | SDL OSD without shaders |

Options: `--clean` (reconfigure), `--clang` (Qt build only, ThinLTO),
`--target <ninja>` (focused target), `--build-dir <dir>`. Extra CMake args
go through `--clean -DFOO=...`.

`AUTOMATION=ON` is set by default: the resulting binary supports the
automation control socket used by the `86box-automation` skill.

Output binary: `<build dir>/src/86Box` (GCC + LTO, with symbols for GDB).

PGO is not viable: `-fprofile-generate` conflicts with the JIT (segfault).
