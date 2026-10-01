# 86box-mtools

Read/write guest DOS disk images (`.scratch/VM/*.IMG`) without booting 86Box.
**All access goes through `scripts/mt`** - an allow-list wrapper over mtools
(4.0.49, Debian) that was verified against MS-DOS.IMG (MBR, FAT16,
partition at sector 63).

## Why the wrapper

An `mformat` slipped into a hand-rolled mtools pipeline on 2026-10-18 and
wiped a guest image (OS + games lost; restored from user backup). `mt` makes
that class of error impossible: it exposes only the commands that are ever
needed, refuses to write while 86Box runs, guards `rmtree` against the
guest root, and has no passthrough. Do not bypass it with raw mtools calls;
if a needed operation is missing, extend `mt` (allow-list + guard) and test
it.

## Usage

```bash
MT=.agents/skills/86box-mtools/scripts/mt
IMG=.scratch/VM/MS-DOS.IMG

$MT $IMG ls GAMES/BLOOD          # list
$MT $IMG cat GAMES/BLOOD/GLIDE2X.OVL | sha256sum
$MT $IMG info /                  # free space
$MT $IMG get GAMES/BLOOD/3DFX.EXE /host/path   # guest -> host
# writes (86Box must be stopped; mt enforces):
$MT $IMG put /host/file OVL/DEST.OVL           # one file (replaces)
$MT $IMG dir /host/dir GAMES/NEW                # whole tree (mcopy -s)
$MT $IMG rm GAMES/BLOOD/OLD.OVL                 # one file
$MT $IMG rmtree GAMES/OLDGAME                   # whole tree (mdeltree)
$MT $IMG mkdir GAMES/NEW                        # one dir
$MT $IMG --offset 32256 ls /                    # non-default partition start
```

Guest paths take `/GAMES/BLOOD` (the wrapper adds `::/`); `::/...` also
works. `deploy.sh <image> <src> <guest-path> [offset]` remains as a
back-compat shim over `mt put`.

## Behavior

- 86Box syncs ramdisks to the image only at clean power-off. `mt` blocks
  put/dir/rm/rmtree/mkdir while `pgrep -f "build/src/86B[o]x"` matches, and
  lets reads through anytime.
- `put` deletes the destination first: mtools' `mcopy` onto an existing
  guest file fails silently (rc=1, no output).
- Writes hit the image on-disk immediately; the guest sees them at next boot.
- Verify a deploy byte-identical before rebooting:
  `sha256sum /host/file` vs `$MT $IMG cat <guest> | sha256sum`.

## Gotchas

- Guest names are 8.3; mtools truncates on write (`GLIDE2X.OVL` is already
  8.3), and `mdir`/`ls` print truncated 8.3 columns - a dir called
  `HOTCGL` lists as `HOTCG`.
- The `@@32256` partition offset lives inside mtools' `-i` argument
  (63 sectors * 512); `mt` handles this, exposed only as `--offset`.
- Do not format or otherwise rewrite an image from outside (`mformat`,
  `dd`, `mkfs`, `wipefs`, whole-file redirect). If an image needs
  rebuilding, stop and ask the user - they may hold backups.
