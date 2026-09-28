# Shell helpers for the Makefile (sourced by every recipe)

# Make `set -e` apply inside $(...) as well
shopt -s inherit_errexit

die()  { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }
warn() { printf '\033[33mWarning:\033[0m %s\n' "$*" >&2; }
hint() { printf '         %s\n' "$*" >&2; }
ok()   { printf '\033[32mOK:\033[0m %s\n' "$*" >&2; }
step() { printf '\n\033[1m==> %s\033[0m\n' "$*" >&2; }

GH_API=https://api.github.com/repos

# confirm <question> – aborts unless the user answers yes
confirm() {
    local answer
    read -r -p "$* [y/N] " answer
    [[ $answer =~ ^[Yy]([Ee][Ss])?$ ]] || die "Aborted"
}

# danger_banner <action> – loud warning before anything that can brick the headset,
# followed by a confirmation. Shown on every run on purpose.
danger_banner() {
    local red=$'\033[1;37;41m' reset=$'\033[0m' line
    for line in \
        "" \
        "  WARNING - THIS CAN BRICK YOUR PLAYSTATION VR2" \
        "" \
        "  About to: $*" \
        "" \
        "  Jailbreaking and flashing firmware are unofficial and may permanently" \
        "  damage the headset. Neither this installer nor the authors of vr2jb and" \
        "  PSVR2Updater take any responsibility." \
        "" \
        "  Keep the headset connected and the PC running until it is finished." \
        "  Guide: https://github.com/BnuuySolutions/PSVR2Toolkit/wiki/Jailbreaking-your-headset" \
        ""; do
        printf '%s%-90s%s\n' "$red" "$line" "$reset" >&2
    done
    confirm "Continue at your own risk?"
}

# --- GitHub releases ------------------------------------------------------------
# <repo> is "owner/name", or just "name" for BnuuySolutions projects.
# <asset> is a regular expression matched against the whole asset name.

# resolve_release <repo> <tag|latest> <asset> [prerelease=no|yes]
# Prints the release JSON. "latest" = newest release that contains <asset>
# (PSVR2Toolkit needs prerelease=yes, the Ignition build is only published as experimental).
resolve_release() {
    local repo=$1 tag=$2 asset=$3 pre=${4:-no} rel
    [[ $repo == */* ]] || repo=BnuuySolutions/$repo
    if [ "$tag" = latest ]; then
        rel=$(curl -fsSL "$GH_API/$repo/releases?per_page=50" | jq -c --arg a "^$asset\$" --arg pre "$pre" '
            [.[] | select(.draft | not)
                 | select($pre == "yes" or (.prerelease | not))
                 | select(any(.assets[]; .name | test($a)))][0] // empty')
    else
        rel=$(curl -fsSL "$GH_API/$repo/releases/tags/$tag") || die "$repo: release '$tag' not found"
    fi
    [ -n "$rel" ] || die "$repo: no release containing $asset found"
    printf '%s\n' "$rel"
}

# fetch_release <repo> <tag|latest> <asset> <dest file> [prerelease]
# Downloads <asset> to <dest file>, verifies it against the sha256 digest from the
# GitHub API and prints the resolved tag.
fetch_release() {
    local repo=$1 tag=$2 asset=$3 dest=$4 pre=${5:-no} rel a name url digest
    rel=$(resolve_release "$repo" "$tag" "$asset" "$pre")
    tag=$(jq -r .tag_name <<<"$rel")
    a=$(jq -c --arg a "^$asset\$" '[.assets[] | select(.name | test($a))][0] // empty' <<<"$rel")
    [ -n "$a" ] || die "$repo $tag: no asset matching $asset"
    name=$(jq -r .name <<<"$a")
    url=$(jq -r .browser_download_url <<<"$a")
    digest=$(jq -r '.digest // empty' <<<"$a")

    printf 'Downloading %s %s (%s)\n' "${repo##*/}" "$tag" "$name" >&2
    curl -fL --retry 3 -# -o "$dest" "$url"
    if [ -n "$digest" ]; then
        echo "${digest#sha256:}  $dest" | sha256sum -c --quiet - >&2 || die "$name: checksum mismatch"
        ok "$name verified (sha256)"
    else
        warn "${repo##*/} $tag: GitHub provides no checksum for $name"
    fi
    printf '%s\n' "$tag"
}

# install_tool <repo> <tag|latest> <asset> <dir> <executable>...
# Installs or updates a zipped release into <dir> (a VERSION file records the tag).
# Keeps the installed version if GitHub cannot be reached.
install_tool() {
    local repo=$1 version=$2 asset=$3 dir=$4 name=${1##*/} installed wanted tmp exe
    shift 4
    case "$dir" in ""|/|"$HOME"|"$HOME/.local"|"$HOME/.local/share") die "Install dir '$dir' is not allowed";; esac
    installed=$(cat "$dir/VERSION" 2>/dev/null || true)
    wanted=$(resolve_release "$repo" "$version" "$asset" 2>/dev/null | jq -r .tag_name) || wanted=
    if [ -z "$wanted" ]; then
        [ -n "$installed" ] || die "Could not resolve $name '$version' on GitHub"
        warn "Could not resolve $name '$version' on GitHub (offline?) – using installed $installed"
        return
    fi
    if [ "$installed" = "$wanted" ] && [ -x "$dir/$1" ]; then
        ok "$name $installed is up to date"
        return
    fi
    step "$name $wanted to $dir"
    tmp=$(mktemp -d)
    fetch_release "$repo" "$wanted" "$asset" "$tmp/release.zip" >/dev/null
    unzip -q "$tmp/release.zip" -d "$tmp/app"
    for exe in "$@"; do chmod 0755 "$tmp/app/$exe"; done
    echo "$wanted" > "$tmp/app/VERSION"
    rm -rf "$dir"
    mkdir -p "$(dirname "$dir")"
    mv "$tmp/app" "$dir"
    rm -rf "$tmp"
    ok "$name $wanted installed"
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

# find_headset – prints the sysfs path of the PSVR2 (054c:0cde), or nothing
find_headset() {
    local d
    for d in /sys/bus/usb/devices/*; do
        if [ "$(cat "$d/idVendor" 2>/dev/null)" = 054c ] && [ "$(cat "$d/idProduct" 2>/dev/null)" = 0cde ]; then
            printf '%s\n' "$d"
            return
        fi
    done
}

# require_headset_idle – headset connected and not in use by SteamVR
require_headset_idle() {
    pgrep -x vrserver >/dev/null && die "SteamVR is running – close it first (the headset must not be in use)"
    [ -n "$(find_headset)" ] || die "PlayStation VR2 not found on USB – power on the headset and check the PC adapter"
    ok "Headset connected, SteamVR not running"
}

# check_headset_usb – is the PSVR2 connected, fast enough and accessible?
check_headset_usb() {
    local dev speed node
    dev=$(find_headset)
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

# --- Firmware ------------------------------------------------------------------------

FW_JAILBREAK=0x06000102   # the only firmware vr2jb works on (v6.00)
FW_NO_DOWNGRADE=0x06100000 # recovery 6.10 or newer cannot be downgraded to 6.00
FW_PC_MIN=0x05000000       # oldest firmware that works on PC

# fw_name <hex version> – 0x06100000 -> v06.10 (notation used by vr2jb and the guide)
fw_name() {
    printf 'v%02x.%02x' $(( ($1 >> 24) & 0xff )) $(( ($1 >> 16) & 0xff ))
}

# firmware_report <PSVR2Updater output> – print the versions readably and explain them
firmware_report() {
    local fw rec
    fw=$(grep -oP '^Version:\s+\K0x[0-9A-Fa-f]+' <<<"$1" || true)
    rec=$(grep -oP '^Recovery Version:\s+\K0x[0-9A-Fa-f]+' <<<"$1" || true)
    if [ -z "$fw" ] || [ -z "$rec" ]; then
        printf '%s\n' "$1"
        warn "Could not parse the firmware versions from PSVR2Updater's output"
        return
    fi
    printf 'Firmware:  %s\nRecovery:  %s\n' "$(fw_name "$fw")" "$(fw_name "$rec")"
    grep -E '^(Commit Hash|PCB ID):' <<<"$1" | sed -E 's/^(Commit Hash|PCB ID):\s*/\1: /' || true
    if (( fw < FW_PC_MIN )); then
        warn "Firmware $(fw_name "$fw") is older than v05.00 and does not work on PC – update it (make firmware-flash)"
    fi
    if (( fw == FW_JAILBREAK )); then
        ok "Firmware v06.00 – ready for 'make jailbreak'"
    elif (( rec >= FW_NO_DOWNGRADE )); then
        warn "Recovery $(fw_name "$rec") is v06.10 or newer – downgrading to v06.00 is impossible, no jailbreak"
    elif (( (fw >> 16) == (FW_JAILBREAK >> 16) )); then
        warn "Firmware is v06.00, but build $fw instead of $FW_JAILBREAK required by vr2jb – flash v06.00 again:"
        hint "make firmware-flash FIRMWARE=/path/to/HMD2_FIRMWARE_V06_00.CUP"
    elif (( fw < FW_JAILBREAK )); then
        warn "Firmware $(fw_name "$fw") is older than v06.00 – for the jailbreak, update to v06.00:"
        hint "make firmware-flash FIRMWARE=/path/to/HMD2_FIRMWARE_V06_00.CUP"
    else
        warn "Firmware $(fw_name "$fw") is newer than v06.00 – for the jailbreak, downgrade to v06.00:"
        hint "make firmware-recovery, then make firmware-flash FIRMWARE=/path/to/HMD2_FIRMWARE_V06_00.CUP"
    fi
}
