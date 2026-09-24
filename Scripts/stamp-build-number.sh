#!/bin/sh
#
#  stamp-build-number.sh — CFBundleVersion, worked out at build time.
#
#  WHAT IT REPLACES. `CURRENT_PROJECT_VERSION: "1"`, typed into project.yml once
#  per target and then never again, which meant every upload to App Store Connect
#  after the first was rejected for reusing build 1 and the fix was to hand-edit
#  three lines in a YAML file and remember which three.
#
#  THE NUMBER IS `<commits>.<YYMMDD>.<HHMM>` — 5.260921.0018 is the fifth commit,
#  built on 21 September 2026 at 00:18 UTC.
#
#  WHY NOT JUST THE COMMIT COUNT, which is shorter and says the one thing you
#  actually want to know. Because it is not unique, and the day it repeats is the
#  worst day for it to: you archive, upload, the upload is rejected for something
#  unrelated — a provisioning profile, a missing icon, an export-compliance
#  answer — you fix it WITHOUT touching a source file, archive again, and App
#  Store Connect refuses the binary because build 5 already exists. The way out
#  is an empty commit made purely to move a number, which is a lie in the history
#  to satisfy a counter. The timestamp costs some length and buys never having
#  that afternoon.
#
#  WHY THE COUNT STAYS FIRST. App Store Connect requires each build to sort above
#  the last within a marketing version, and it sorts component by component. The
#  count is the only part that is monotonic no matter what, so it leads. The date
#  is second and the clock third for the same reason — `HHMM` alone would go
#  BACKWARDS at midnight, which is exactly the kind of bug that surfaces at 00:18
#  and not before.
#
#  If you ever do want the bare count, the `version` line below is the one line
#  to change; nothing else knows the format.
#
set -eu

# `|| echo 0` is not defensive noise: a source archive unpacked without .git
# still has to build, and it should get a real number rather than a failure.
root="${SRCROOT:-$(dirname "$0")/..}"
commits=$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 0)
version="${commits}.$(date -u +%y%m%d).$(date -u +%H%M)"

# `make version` — what the next build would stamp, without building it. The
# format lives in exactly one place and this is how you read it from outside.
if [ "${1:-}" = "--print" ]; then
    echo "$version"
    exit 0
fi

# A build with no plist to stamp is a build with nothing to break — preview
# builds and index builds both land here. Say nothing and leave.
plist="${TARGET_BUILD_DIR:-}/${INFOPLIST_PATH:-}"
[ -f "$plist" ] || exit 0

/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${version}" "$plist"
echo "note: build number ${version}"
