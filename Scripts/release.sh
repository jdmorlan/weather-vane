#!/bin/bash
#
#  release.sh — the real Vane, built and shipped from the terminal.
#
#      Scripts/release.sh ios          iPhone + iPad → TestFlight
#      Scripts/release.sh tv           Apple TV      → TestFlight
#      Scripts/release.sh mac          Mac → notarized → /Applications
#      Scripts/release.sh all          all three, Mac last (it waits the longest)
#
#      add --no-upload to build and sign everything but send nothing to Apple;
#      the result lands in build/export/ — a check that signing works.
#
#  (`make release-ios`, `make release-tv`, `make release-mac`, `make release`.)
#
#  WHAT IT REPLACES. Picking the scheme, then the right "Any … Device"
#  destination, then Product → Archive, then three screens of Organizer. Each is
#  one decision this script makes the same way every time — which is the point:
#  the wrong destination does not fail, it archives a simulator build that
#  refuses to upload ten minutes later.
#
#  ARCHIVES GO WHERE XCODE PUTS THEM, ~/Library/Developer/Xcode/Archives, so the
#  Organizer still lists every one. That matters after the fact: crash reports
#  from TestFlight are symbolicated against the archive that made the build.
#
#  SIGNING IS XCODE'S, NOT OURS. `-allowProvisioningUpdates` lets xcodebuild use
#  the Apple ID signed into Xcode → Settings → Accounts, exactly as clicking
#  through would. There is no key or password in this script or beside it.
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
TEAM=CG68B3UD28
LOGS="$ROOT/build/logs"
STAMP=$(date +%Y%m%d-%H%M%S)

upload=1
targets=()
for arg in "$@"; do
    case "$arg" in
        --no-upload) upload=0 ;;
        mac|ios|tv) targets+=("$arg") ;;
        all) targets+=(ios tv mac) ;;
        *) sed -n '3,12p' "$0" | sed 's/^#  \{0,1\}//'; exit 1 ;;
    esac
done
[ ${#targets[@]} -gt 0 ] || { sed -n '3,12p' "$0" | sed 's/^#  \{0,1\}//'; exit 1; }

say()  { printf '\n\033[1m▸ %s\033[0m\n' "$*"; }
fail() { printf '\n\033[31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# Quiet on success, the whole story on failure. xcodebuild's full output is
# thousands of lines of which the one that matters is near the bottom — so it
# goes to a log, and only the tail comes back when something breaks.
run() {
    local log="$LOGS/$1.log"; shift
    mkdir -p "$LOGS"
    if ! "$@" >"$log" 2>&1; then
        echo; grep -E "error:|Error Domain|ERROR" "$log" | tail -15 || tail -30 "$log"
        fail "Failed. Full log: ${log#$ROOT/}"
    fi
}

# --- Before anything is built -------------------------------------------------

command -v xcodegen >/dev/null || fail "xcodegen isn't installed: brew install xcodegen"

# THE BUILD IS WHAT IS ON DISK, not what is committed. Shipping uncommitted
# work is sometimes exactly right, but it should be a decision rather than a
# surprise — and the build number's commit count would not describe it.
if [ -n "$(git status --porcelain)" ] && [ $upload -eq 1 ]; then
    git status --short
    read -r -p "Uncommitted changes above will be in this build. Ship anyway? [y/N] " ok
    [ "$ok" = y ] || [ "$ok" = Y ] || exit 1
fi

# The project is generated and not committed, so it is only as current as the
# last `make generate`. Regenerating costs a second and removes the question.
say "Regenerating the Xcode project"
run "$STAMP-xcodegen" xcodegen generate
echo "  build number will be $(Scripts/stamp-build-number.sh --print)"

# --- The steps ----------------------------------------------------------------

# Options for the export step, written fresh each time from the two things that
# vary. `manageAppVersionAndBuildNumber: false` is load-bearing: left at its
# default, the upload rewrites the build number that stamp-build-number.sh chose.
export_options() {  # method destination → path
    local plist="$ROOT/build/ExportOptions-$1-$2.plist"
    mkdir -p "$ROOT/build"
    cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>$1</string>
    <key>destination</key><string>$2</string>
    <key>teamID</key><string>$TEAM</string>
    <key>signingStyle</key><string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key><false/>
    <key>uploadSymbols</key><true/>
</dict>
</plist>
EOF
    echo "$plist"
}

archive() {  # scheme platform label → sets ARCHIVE
    local dir="$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)"
    ARCHIVE="$dir/$1 $(date '+%-m-%-d-%y, %-I.%M %p').xcarchive"
    mkdir -p "$dir"
    say "Archiving $3 ($1, Release)"
    run "$STAMP-$1-archive" xcodebuild archive \
        -project Vane.xcodeproj -scheme "$1" -configuration Release \
        -destination "generic/platform=$2" -archivePath "$ARCHIVE" \
        -allowProvisioningUpdates
    echo "  ${ARCHIVE/#$HOME/~}"
}

# iPhone/iPad and TV are ONE App Store record (the TV carries the iOS bundle
# id — see project.yml), so both go the same way: signed for the App Store and
# uploaded. Processing takes Apple 10–30 minutes; the build then appears on the
# TestFlight tab and TestFlight on each device offers it.
testflight() {  # scheme platform label
    archive "$1" "$2" "$3"
    if [ $upload -eq 0 ]; then
        run "$STAMP-$1-export" xcodebuild -exportArchive -archivePath "$ARCHIVE" \
            -exportOptionsPlist "$(export_options app-store-connect export)" \
            -exportPath "$ROOT/build/export/$1" -allowProvisioningUpdates
        say "$3 signed for the App Store, not uploaded: build/export/$1"
        return
    fi
    say "Uploading $3 to App Store Connect"
    run "$STAMP-$1-upload" xcodebuild -exportArchive -archivePath "$ARCHIVE" \
        -exportOptionsPlist "$(export_options app-store-connect upload)" \
        -exportPath "$ROOT/build/export/$1" -allowProvisioningUpdates
    echo "  Uploaded. Apple emails when it has processed (10–30 min); then install from TestFlight."
}

# The Mac goes outside the App Store (TestFlight on the Mac requires the App
# Sandbox, which Vane does not use — see Weather.entitlements): signed with
# Developer ID, sent to Apple to be notarized, and copied into /Applications
# once Apple has vouched for it.
mac() {
    archive Vane macOS "the Mac app"
    local out="$ROOT/build/export/Vane"
    rm -rf "$out"

    if [ $upload -eq 0 ]; then
        run "$STAMP-Vane-export" xcodebuild -exportArchive -archivePath "$ARCHIVE" \
            -exportOptionsPlist "$(export_options developer-id export)" \
            -exportPath "$out" -allowProvisioningUpdates
        say "Mac app signed with Developer ID, not notarized: build/export/Vane"
        return
    fi

    say "Sending the Mac app to Apple for notarization"
    run "$STAMP-Vane-notarize" xcodebuild -exportArchive -archivePath "$ARCHIVE" \
        -exportOptionsPlist "$(export_options developer-id upload)" \
        -exportPath "$out" -allowProvisioningUpdates

    # There is no "wait" flag for this path: -exportNotarizedApp simply fails
    # until Apple has finished, so ask every 30 seconds. Usually 2–10 minutes.
    printf "  waiting for Apple"
    local tries=0
    until xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$out" \
            >"$LOGS/$STAMP-Vane-fetch.log" 2>&1; do
        tries=$((tries + 1))
        [ $tries -lt 80 ] || { echo; fail "Not notarized after 40 minutes. Try again later with:
    xcodebuild -exportNotarizedApp -archivePath \"$ARCHIVE\" -exportPath \"$out\""; }
        printf "."; sleep 30
    done
    echo " notarized."

    # Gatekeeper's own verdict, not ours: this is the check a downloaded app
    # would face, and it is what says the notarization actually took.
    spctl --assess --type execute "$out/Vane.app" 2>/dev/null \
        || fail "Gatekeeper rejected the notarized app: spctl -a -vv \"$out/Vane.app\""

    # Never quit it for you — it may be mid-backfill, and it is yours to close.
    while pgrep -qf "^/Applications/Vane.app/Contents/MacOS/Vane"; do
        read -r -p "  Vane is running from /Applications. Quit it, then press return. "
    done
    say "Installing into /Applications"
    rm -rf /Applications/Vane.app
    ditto "$out/Vane.app" /Applications/Vane.app
    echo "  /Applications/Vane.app — $(defaults read /Applications/Vane.app/Contents/Info CFBundleVersion)"
}

for t in "${targets[@]}"; do
    case "$t" in
        ios) testflight VaneiOS iOS "iPhone and iPad" ;;
        tv)  testflight VaneTV tvOS "the TV" ;;
        mac) mac ;;
    esac
done
say "Done."
