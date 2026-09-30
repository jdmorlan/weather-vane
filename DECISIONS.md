# Decisions

Running record. Each entry is what was decided, and why.

## 1. The Mac app is sandboxed, and ships through TestFlight

It reads no file it was not handed, runs no other program, loads no outside
code and drives no other app, so the sandbox costs it nothing. Sandboxed, the
Mac shares the App Store record with the other platforms and updates through
TestFlight like them.
Inside it, the app is granted network access.

Until 30 September 2026 it was not sandboxed, and not by choice: Vane was
lifted out of Almanac and read its archive from Almanac's own folder, which a
sandboxed app cannot see. Once the archive lived in the app group container,
nothing needed the freedom, and the unsandboxed setup had only been inherited.
It also meant the Mac could take the iOS bundle id, jdmorlan.vane.ios, and join
the one listing. See Weather.entitlements.

Decided by `appleship decide mac`. If what the app does changes, run it again.
