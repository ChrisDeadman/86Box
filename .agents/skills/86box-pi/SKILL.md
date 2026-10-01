---
name: 86box-pi
description: Build, deploy, and service-control the Raspberry Pi 5 build of 86Box (SSH to the Pi, cross-build, swap the binary, restart the S99retro86 service). Use for any Pi deployment or Pi log inspection.
---

# Raspberry Pi 5 86Box

Target: `root@192.168.1.113` (ssh key authorized). Service: `S99retro86`.
Binary ships with debug symbols. Logfile: `/mnt/nvme/WIN98SE/86box.log`.

| Action | Command |
|---|---|
| Build | `~/Projects/rpi-things/retro86/tools/build.sh pi5 86box-rebuild` |
| Stop | `ssh root@192.168.1.113 -C '/etc/init.d/S99retro86 stop'` |
| Deploy | `scp ~/Projects/rpi-things/retro86/output/build/build/86box-custom/src/86Box root@192.168.1.113:/usr/bin/` |
| Start | `ssh root@192.168.1.113 -C '/etc/init.d/S99retro86 start'` |

Deploy flow: stop, deploy, start.
