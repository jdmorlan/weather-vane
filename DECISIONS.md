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

## 2. Each destination has a link, and Debug has its own scheme

`vane://now`, `vane://rain`, `vane://forecast-check` and the rest open that
destination on every platform that has it; each app ignores links to screens it
does not have (the iPhone has Now, Map and Rain; the TV Now, Forecast, Map and
Videos). Added so `appleship screenshots` can visit each screen and
photograph it for a README or a post, without a UI-test target; the screens it
visits are listed in appleship.yml.

The names are their own list (`Destination.slug`), not the sidebar labels, so
rewording a label does not break a link written somewhere else.

Debug answers to `vane-dev://` instead. Vane and Vane Dev are installed side
by side, and when two apps claim one scheme the system picks which one opens
the link.
