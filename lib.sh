# Shell helpers for the Makefile (sourced by every recipe)

# Make `set -e` apply inside $(...) as well
shopt -s inherit_errexit

die()  { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[33mWarning:\033[0m %s\n' "$*" >&2; }
hint() { printf '         %s\n' "$*" >&2; }
ok()   { printf '\033[32mOK:\033[0m %s\n' "$*" >&2; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*" >&2; }

GH_API=https://api.github.com/repos/BnuuySolutions

# --- GitHub releases ------------------------------------------------------------

# resolve_release <repo> <tag|latest> <asset> [prerelease=no|yes]
# Prints the release JSON. "latest" = newest release that contains <asset>
# (PSVR2Toolkit needs prerelease=yes, the Ignition build is only published as experimental).
resolve_release() {
    local repo=$1 tag=$2 asset=$3 pre=${4:-no} rel
    if [ "$tag" = latest ]; then
        rel=$(curl -fsSL "$GH_API/$repo/releases?per_page=50" | jq -c --arg a "$asset" --arg pre "$pre" '
            [.[] | select(.draft | not)
                 | select($pre == "yes" or (.prerelease | not))
                 | select(any(.assets[]; .name == $a))][0] // empty')
    else
        rel=$(curl -fsSL "$GH_API/$repo/releases/tags/$tag") || die "$repo: release '$tag' not found"
    fi
    [ -n "$rel" ] || die "$repo: no release containing $asset found"
    printf '%s\n' "$rel"
}

# fetch_release <repo> <tag|latest> <asset> <dest dir> [prerelease]
# Downloads <asset> into <dest dir>, verifies it against the sha256 digest from the
# GitHub API and prints the resolved tag.
fetch_release() {
    local repo=$1 tag=$2 asset=$3 dest=$4 pre=${5:-no} rel url digest
    rel=$(resolve_release "$repo" "$tag" "$asset" "$pre")
    tag=$(jq -r .tag_name <<<"$rel")
    url=$(jq -r --arg a "$asset" '.assets[] | select(.name == $a) | .browser_download_url' <<<"$rel")
    digest=$(jq -r --arg a "$asset" '.assets[] | select(.name == $a) | .digest // empty' <<<"$rel")
    [ -n "$url" ] || die "$repo $tag: asset $asset missing"

    printf 'Downloading %s %s (%s)\n' "$repo" "$tag" "$asset" >&2
    curl -fL --retry 3 -# -o "$dest/$asset" "$url"
    if [ -n "$digest" ]; then
        echo "${digest#sha256:}  $dest/$asset" | sha256sum -c --quiet - >&2 || die "$asset: checksum mismatch"
        ok "$asset verified (sha256)"
    else
        warn "$repo $tag: GitHub provides no checksum for $asset"
    fi
    printf '%s\n' "$tag"
}

# --- Steam ----------------------------------------------------------------------

# steam_app_library <steam dir> <appid>
# Prints the Steam library path that contains <appid>, or nothing if not installed.
steam_app_library() {
    local steam=$1 appid=$2 lib
    while IFS= read -r lib; do
        if [ -f "$lib/steamapps/appmanifest_$appid.acf" ]; then
            printf '%s\n' "$lib"
            return
        fi
    done < <({ echo "$steam"; grep -oP '"path"\s+"\K[^"]+' "$steam/steamapps/libraryfolders.vdf" 2>/dev/null || true; })
}

# check_steam_app <steam dir> <appid> <name>
# Fails unless <appid> is installed in the main Steam library (Ignition and the
# upstream scripts only look there).
check_steam_app() {
    local steam=$1 appid=$2 name=$3 lib main
    lib=$(steam_app_library "$steam" "$appid")
    [ -n "$lib" ] || die "$name is not installed – install it in Steam (app $appid)"
    main=$(readlink -f "$steam")
    if [ "$(readlink -f "$lib")" != "$main" ]; then
        die "$name is installed in $lib, but must be in the main library $main" \
            "– move it in Steam: Properties > Installed Files > Move install folder"
    fi
    ok "$name installed"
}

# --- Diagnostics ------------------------------------------------------------------

# check_headset_usb – is the PSVR2 (054c:0cde) connected, fast enough and accessible?
check_headset_usb() {
    local dev="" d speed node
    for d in /sys/bus/usb/devices/*; do
        if [ "$(cat "$d/idVendor" 2>/dev/null)" = 054c ] && [ "$(cat "$d/idProduct" 2>/dev/null)" = 0cde ]; then
            dev=$d
            break
        fi
    done
    if [ -z "$dev" ]; then
        warn "PlayStation VR2 not found on USB"
        hint "Check: headset plugged into the PC adapter, adapter's power supply connected,"
        hint "adapter's USB cable in a USB 3 port, DisplayPort cable connected to the GPU."
        return
    fi
    speed=$(cat "$dev/speed")
    if [ "$speed" -lt 5000 ]; then
        warn "PlayStation VR2 connected at only $speed Mbit/s (USB 3 = 5000 Mbit/s)"
        hint "The PC adapter needs a USB 3 port. Use a rear port directly on the mainboard,"
        hint "no hub, no extension cable, no front-panel port. Otherwise the headset drops out."
    else
        ok "PlayStation VR2 connected via USB ($speed Mbit/s)"
    fi
    node=$(printf '/dev/bus/usb/%03d/%03d' "$(cat "$dev/busnum")" "$(cat "$dev/devnum")")
    if [ -w "$node" ]; then
        ok "Headset USB device is accessible ($node)"
    else
        warn "No write access to $node – xr-hardware udev rules missing? (make xr-hardware, then replug)"
    fi
}

# check_headset_display – is the PSVR2 display (EDID manufacturer SNY, product 0xC207)
# visible on a GPU output? Without it SteamVR cannot DRM-lease the display.
check_headset_display() {
    local c
    for c in /sys/class/drm/card*-*; do
        [ "$(cat "$c/status" 2>/dev/null)" = connected ] || continue
        if [ "$(od -An -tx1 -j8 -N4 "$c/edid" 2>/dev/null | tr -d ' \n')" = 4dd907c2 ]; then
            ok "PlayStation VR2 display connected (${c##*/})"
            return
        fi
    done
    warn "PlayStation VR2 display not found on any GPU output"
    hint "Connect the PC adapter's DisplayPort cable directly to the GPU (no adapters)."
    hint "Without it SteamVR reports 'your desktop environment might not support VR'."
}

# check_vrserver_log <log dir> – hints from the last SteamVR run
check_vrserver_log() {
    local log="$1/vrserver.txt" run
    if [ ! -f "$log" ]; then
        warn "No SteamVR log yet ($log) – start SteamVR"
        return
    fi
    # vrserver.txt holds several runs; only look at the last one
    run=$(awk '/vrserver .* startup with PID/ { buf = "" } { buf = buf $0 "\n" } END { printf "%s", buf }' "$log")
    printf 'Last run: %s (%s)\n' "$(head -1 <<<"$run" | cut -c1-24)" "$log" >&2
    if grep -q 'Using safe mode' <<<"$run"; then
        warn "SteamVR started in safe mode after a crash"
        # The crash that caused safe mode is logged at the end of the previous run
        if grep 'Failed Watchdog timeout' "$log" | tail -1 | grep -q playstation_vr2; then
            hint "Cause: the PSVR2 driver hung while loading. This happens when SteamVR restarts"
            hint "too quickly."
        fi
        hint "Close SteamVR, wait ~10 s, then start it again."
    fi
    if ! grep -q 'playstation_vr2: PlayStation VR2 Toolkit' <<<"$run"; then
        warn "SteamVR did not load the PSVR2 driver through Ignition"
        hint "Look for 'playstation_vr2' or 'ignition' errors in $log"
        return
    fi
    ok "PSVR2 driver + toolkit loaded through Ignition"
    if grep -qE 'playstation_vr2: \[Error\] (Bulk|Control) transfer' <<<"$run"; then
        warn "USB transfers to the headset failed – the connection dropped"
        hint "Almost always a cable/port problem, see the headset check above."
    fi
}

# check_driver_blocked <steamvr.vrsettings> – did SteamVR disable the PSVR2 driver?
check_driver_blocked() {
    [ -f "$1" ] || return 0
    if jq -e '.driver_playstation_vr2 | (.enable == false) or (.blocked_by_safe_mode == true)' "$1" >/dev/null 2>&1; then
        warn "SteamVR has disabled the PSVR2 driver in $1"
        hint "Run 'make unblock-driver' (with SteamVR closed)."
    else
        ok "PSVR2 driver not disabled in SteamVR settings"
    fi
}
