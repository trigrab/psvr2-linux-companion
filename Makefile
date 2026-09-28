# PSVR2 Linux Companion – installs Ignition + PSVR2Toolkit (PlayStation VR2 on Linux with SteamVR)
#
# Follows https://github.com/BnuuySolutions/PSVR2Toolkit/wiki/Linux-support
# Releases are downloaded from GitHub on demand (default: latest), verified against
# the sha256 digest from the GitHub API and deleted afterwards.
# Do not run with sudo – sudo is only used for /opt, /etc/udev and /usr.

SHELL       := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.ONESHELL:
.NOTPARALLEL:
.DEFAULT_GOAL := help

# --- Versions: "latest" or a tag, e.g. IGNITION_VERSION=v1.1.0 --------------
IGNITION_VERSION ?= latest
PSVR2TK_VERSION  ?= latest
SVLF_VERSION     ?= latest
PLAYAREA_VERSION ?= latest
VR2JB_VERSION    ?= latest
UPDATER_VERSION  ?= latest

# --- Paths ----------------------------------------------------------------------
IGNITION_DIR ?= /opt/ignition
STEAM_DIR    ?= $(or $(firstword $(wildcard $(HOME)/.steam/steam $(HOME)/.local/share/Steam)),$(HOME)/.steam/steam)
PLUGIN_DIR   ?= $(STEAM_DIR)/steamapps/common/PlayStation VR2 App/SteamVR_Plug-In
VRPATHS      ?= $(HOME)/.config/openvr/openvrpaths.vrpath
VRSETTINGS   ?= $(STEAM_DIR)/config/steamvr.vrsettings
VRLOGS       ?= $(STEAM_DIR)/logs
UDEV_RULE    ?= /etc/udev/rules.d/70-xrhardware.rules
PLAYAREA_DIR ?= $(HOME)/.local/share/PSVR2Toolkit.UnitySetup
VR2JB_DIR    ?= $(HOME)/.local/share/vr2jb
UPDATER_DIR  ?= $(HOME)/.local/share/PSVR2Updater
VK_LAYER     := /usr/share/vulkan/implicit_layer.d/VkLayer_steamvr_linux_fixes.json
VK_LAYER_LIB := /usr/lib/libsteamvr_linux_fixes.so

# Proton version used for the Ignition server (empty = upstream auto-selection)
PROTON_VERSION ?= Proton - Experimental

SUDO ?= sudo

XRHW_URL := https://gitlab.freedesktop.org/monado/utilities/xr-hardware/-/raw/main/70-xrhardware.rules

# Steam app IDs
APP_STEAMVR := 250820
APP_PSVR2   := 2580190
APP_PROTON  := 1493710

LINUX64 = $(PLUGIN_DIR)/bin/linux64
WIN64   = $(PLUGIN_DIR)/bin/win64
DRIVER_REGISTERED = jq -r '.external_drivers[]?' "$(VRPATHS)" | grep -q 'PlayStation VR2 App/SteamVR_Plug-In'

# Every recipe: load helpers, create a temporary download dir that is removed on exit
LIB := . "$(CURDIR)/lib.sh"; tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT

ifeq ($(shell id -u),0)
$(error Do not run as root / with sudo – sudo is invoked where needed)
endif

define HELP
PSVR2 Linux Companion – Ignition + PSVR2Toolkit for PlayStation VR2 on Linux

  make check            Check prerequisites
  make versions         Show which releases would be installed
  make install          Install everything: xr-hardware linux-fixes ignition
                        driver psvr2tk register
  make status           Show installation state, headset connection and last SteamVR run
  make playarea         Set up play area, eye tracking, lenses (PSVR2Toolkit.UnitySetup)
  make reapply          After Steam updated the PlayStation VR2 App: driver + psvr2tk again
  make steamvr-settings Set recommended options in steamvr.vrsettings
  make unblock-driver   Re-enable the PSVR2 driver if SteamVR disabled it after a crash

  Optional – jailbreak (vibration, eye tracking camera; firmware 6.00 only, can brick):
    firmware            Show headset firmware and what to do for the jailbreak
    firmware-recovery   Enter recovery mode to downgrade (vr2jb downgrade)
    firmware-flash      Flash a firmware file: make firmware-flash FIRMWARE=file.CUP
    jailbreak           Run vr2jb – after every headset power-on, before SteamVR

  Individual steps:
    xr-hardware   udev rules to $(UDEV_RULE)   (sudo)
    linux-fixes   SteamVRLinuxFixes Vulkan layer to /usr          (sudo)
    ignition      Ignition release to $(IGNITION_DIR)                  (sudo)
    driver        Run install_ignition.sh on the PSVR2 plug-in
    psvr2tk       PSVR2Toolkit to bin/win64 (original -> *_orig.dll)
    register      Run driver_install.sh (register the driver with SteamVR)

  make uninstall        Unregister, remove toolkit/shim/Ignition and the tools in ~/.local/share,
                        restore Sony's DLL
  make uninstall-all    Additionally remove udev rules and Vulkan layer

Variables: IGNITION_VERSION PSVR2TK_VERSION SVLF_VERSION PLAYAREA_VERSION VR2JB_VERSION
UPDATER_VERSION (default: latest), IGNITION_DIR STEAM_DIR PLUGIN_DIR PLAYAREA_DIR VR2JB_DIR
UPDATER_DIR PROTON_VERSION SUDO
Example:   make install IGNITION_VERSION=v1.1.0
endef
export HELP

.PHONY: help check versions install reapply status \
        xr-hardware linux-fixes ignition driver psvr2tk register steamvr-settings unblock-driver \
        playarea playarea-install vr2jb-install updater-install \
        firmware firmware-recovery firmware-flash jailbreak \
        uninstall uninstall-all unregister uninstall-psvr2tk uninstall-driver \
        uninstall-ignition uninstall-playarea uninstall-jailbreak uninstall-xr-hardware uninstall-linux-fixes

help:
	@printf '%s\n' "$$HELP"

# --- Checks ------------------------------------------------------------------------

check:
	@$(LIB)
	step "Prerequisites"
	for c in curl unzip jq sha256sum; do
	  command -v $$c >/dev/null || die "'$$c' is missing (e.g. sudo apt install $$c)"
	done
	ok "curl, unzip, jq, sha256sum found"
	[ -d "$(STEAM_DIR)/steamapps" ] || die "Steam not found at $(STEAM_DIR) (set STEAM_DIR=...)"
	ok "Steam: $$(readlink -f "$(STEAM_DIR)")"
	[ -d "$(HOME)/.var/app/com.valvesoftware.Steam" ] && warn "Flatpak Steam found – it is not supported, use the native Steam package"
	check_steam_app "$(STEAM_DIR)" $(APP_STEAMVR) SteamVR
	check_steam_app "$(STEAM_DIR)" $(APP_PSVR2) "PlayStation VR2 App"
	if [ "$(PROTON_VERSION)" = "Proton - Experimental" ]; then
	  check_steam_app "$(STEAM_DIR)" $(APP_PROTON) "Proton Experimental"
	elif [ -n "$(PROTON_VERSION)" ]; then
	  [ -f "$(STEAM_DIR)/steamapps/common/$(PROTON_VERSION)/proton" ] \
	    || [ -f "$(STEAM_DIR)/compatibilitytools.d/$(PROTON_VERSION)/proton" ] \
	    || die "'$(PROTON_VERSION)' not found in $(STEAM_DIR)"
	  ok "$(PROTON_VERSION) installed"
	fi
	# steamvr.vrsettings is only created by SteamVR itself (openvrpaths.vrpath is
	# also created by vrpathreg, so it proves nothing)
	[ -f "$(VRSETTINGS)" ] || die "SteamVR has never been started – start it once, close it, then run this again"
	ok "SteamVR has been started before"

versions:
	@$(LIB)
	show() { local rel; rel=$$(resolve_release "$$1" "$$2" "$$3" "$${4:-no}"); printf '%-25s %s\n' "$${1##*/}" "$$(jq -r .tag_name <<<"$$rel")"; }
	show Ignition          "$(IGNITION_VERSION)" Ignition-Linux-Windows.zip
	show PSVR2Toolkit      "$(PSVR2TK_VERSION)"  PSVR2TK-win64-Ignition.zip yes
	show SteamVRLinuxFixes "$(SVLF_VERSION)"     VK_LAYER_BNUUY_steamvr_linux_fixes.zip
	show PSVR2Toolkit.UnitySetup "$(PLAYAREA_VERSION)" '$(PLAYAREA_ZIP)'
	show vr2jb             "$(VR2JB_VERSION)"    '$(VR2JB_ZIP)'
	show RealSupremium/PSVR2Updater "$(UPDATER_VERSION)" '$(UPDATER_ZIP)'

# --- Installation -------------------------------------------------------------------

install: check xr-hardware linux-fixes ignition driver psvr2tk register
	@. "$(CURDIR)/lib.sh"
	step "Done"
	echo "Start SteamVR (not the PlayStation VR2 App – it does not run on Linux)."
	echo "Headset and Sense controllers should show up green. If not: make status"
	echo "For 6DoF tracking, set up your play area once: make playarea"
	echo "Optional: make steamvr-settings"

reapply: driver psvr2tk

xr-hardware:
	@$(LIB)
	step "xr-hardware udev rules"
	curl -fsSL --retry 3 -o "$$tmp/rules" "$(XRHW_URL)"
	$(SUDO) install -m 0644 "$$tmp/rules" "$(UDEV_RULE)"
	$(SUDO) udevadm control --reload-rules
	$(SUDO) udevadm trigger
	ok "$(UDEV_RULE) (replug the headset if it is already connected)"

linux-fixes:
	@$(LIB)
	step "SteamVRLinuxFixes"
	fetch_release SteamVRLinuxFixes "$(SVLF_VERSION)" VK_LAYER_BNUUY_steamvr_linux_fixes.zip "$$tmp/svlf.zip" >/dev/null
	unzip -q "$$tmp/svlf.zip" -d "$$tmp/svlf"
	$(SUDO) "$$tmp/svlf/install.sh"

ignition:
	@$(LIB)
	step "Ignition to $(IGNITION_DIR)"
	case "$(IGNITION_DIR)" in ""|/|/opt|/usr|"$(HOME)") die "IGNITION_DIR='$(IGNITION_DIR)' is not allowed";; esac
	tag=$$(fetch_release Ignition "$(IGNITION_VERSION)" Ignition-Linux-Windows.zip "$$tmp/ignition.zip")
	unzip -q "$$tmp/ignition.zip" -d "$$tmp/ignition"
	echo "$$tag" > "$$tmp/ignition/VERSION"
	chmod 0755 "$$tmp/ignition"/*.sh "$$tmp/ignition/proton"
	chmod 0644 "$$tmp/ignition/VERSION" "$$tmp/ignition/wine_hidraw.reg"
	$(SUDO) rm -rf "$(IGNITION_DIR)"
	$(SUDO) mkdir -p "$(IGNITION_DIR)"
	$(SUDO) cp -r "$$tmp/ignition"/. "$(IGNITION_DIR)/"
	ok "Ignition $$tag in $(IGNITION_DIR)"

driver:
	@. "$(CURDIR)/lib.sh"
	step "Ignition shim for $(PLUGIN_DIR)"
	[ -x "$(IGNITION_DIR)/install_ignition.sh" ] || die "Ignition is not installed (make ignition)"
	"$(IGNITION_DIR)/install_ignition.sh" "$(PLUGIN_DIR)"
	if [ -n "$(PROTON_VERSION)" ]; then
	  # Pin PROTONVERSION instead of the "newest" version picked via sort -V
	  sed -i '2i export PROTONVERSION="$${PROTONVERSION:-$(PROTON_VERSION)}"' "$(LINUX64)/launch_serverhelper.sh"
	  ok "Proton pinned to '$(PROTON_VERSION)'"
	fi

register:
	@. "$(CURDIR)/lib.sh"
	step "Register driver with SteamVR"
	[ -f "$(VRSETTINGS)" ] || die "SteamVR has never been started – start it once, close it, then run 'make register'"
	[ -x "$(LINUX64)/driver_install.sh" ] || die "Ignition shim missing (make driver)"
	"$(LINUX64)/driver_install.sh"
	$(DRIVER_REGISTERED) || die "Driver missing from external_drivers in $(VRPATHS)"
	ok "Registered in $(VRPATHS)"

# The toolkit replaces driver_playstation_vr2.dll; Sony's original becomes *_orig.dll.
# .psvr2tk-manifest (sha256sum of the installed files) prevents a second run or a
# toolkit update from overwriting the original. If a Steam update replaced the DLL,
# it no longer matches the manifest and is backed up as the new original.
psvr2tk:
	@$(LIB)
	step "PSVR2Toolkit to bin/win64"
	tag=$$(fetch_release PSVR2Toolkit "$(PSVR2TK_VERSION)" PSVR2TK-win64-Ignition.zip "$$tmp/tk.zip" yes)
	unzip -q "$$tmp/tk.zip" -d "$$tmp/tk"
	cd "$(WIN64)" 2>/dev/null || die "$(WIN64) missing – is the PlayStation VR2 App installed?"
	dll=driver_playstation_vr2.dll orig=driver_playstation_vr2_orig.dll
	[ -f "$$dll" ] || die "$$dll missing – let Steam verify the PlayStation VR2 App's files"
	current=$$(sha256sum "$$dll" | cut -d' ' -f1)
	if [ -f .psvr2tk-manifest ] && grep -q "^$$current  $$dll$$" .psvr2tk-manifest; then
	  ok "Toolkit DLL active, original left untouched"
	elif [ -f "$$orig" ] && [ ! -f .psvr2tk-manifest ]; then
	  die "$$orig exists but there is no manifest – check manually which DLL is Sony's original"
	else
	  mv -f "$$dll" "$$orig"
	  ok "Sony's original backed up as $$orig"
	fi
	cp -f "$$tmp/tk"/* .
	(cd "$$tmp/tk" && sha256sum *) > .psvr2tk-manifest
	echo "$$tag" > .psvr2tk-version
	ok "PSVR2Toolkit $$tag installed ($$(wc -l < .psvr2tk-manifest) files)"

# --- Play area (PSVR2Toolkit.UnitySetup) ---------------------------------------------
# Replaces the PlayStation VR2 App's room setup: play area, eye tracking calibration,
# lens adjustment. Runs as a native Linux OpenVR app while SteamVR is running.

PLAYAREA_ZIP := PSVR2Toolkit.UnitySetup-Linux.zip
PLAYAREA_BIN := PSVR2Toolkit.UnitySetup.x86_64

playarea: playarea-install
	@. "$(CURDIR)/lib.sh"
	step "Play area setup"
	pgrep -x vrserver >/dev/null || die "SteamVR is not running – start it and wait until the headset is green"
	echo "Put on the headset. Look around until the map score is good, draw the play area,"
	echo "then press Save. Quit the tool from its menu to return here."
	echo "Log: $(PLAYAREA_DIR)/run.log"
	cd "$(PLAYAREA_DIR)"
	./$(PLAYAREA_BIN) > run.log 2>&1

playarea-install:
	@. "$(CURDIR)/lib.sh"
	install_tool PSVR2Toolkit.UnitySetup "$(PLAYAREA_VERSION)" '$(PLAYAREA_ZIP)' "$(PLAYAREA_DIR)" $(PLAYAREA_BIN)

# --- Jailbreak and firmware (vr2jb, PSVR2Updater) – optional ---------------------------
# The jailbreak unlocks headset vibration and the eye tracking camera feed. It only works
# on firmware 6.00 and is not persistent: run it after every headset power-on, before
# SteamVR. See https://github.com/BnuuySolutions/PSVR2Toolkit/wiki/Jailbreaking-your-headset

VR2JB_ZIP   := vr2jb-windows-linux-builds.*\.zip
UPDATER_ZIP := build-release-ubuntu-latest\.zip

vr2jb-install:
	@. "$(CURDIR)/lib.sh"
	install_tool vr2jb "$(VR2JB_VERSION)" '$(VR2JB_ZIP)' "$(VR2JB_DIR)" vr2jb

updater-install:
	@. "$(CURDIR)/lib.sh"
	install_tool RealSupremium/PSVR2Updater "$(UPDATER_VERSION)" '$(UPDATER_ZIP)' "$(UPDATER_DIR)" PSVR2Updater

firmware: updater-install
	@. "$(CURDIR)/lib.sh"
	step "Headset firmware"
	require_headset_idle
	out=$$("$(UPDATER_DIR)/PSVR2Updater" 2>&1) || { printf '%s\n' "$$out"; die "PSVR2Updater failed"; }
	firmware_report "$$out"

# Puts the headset into recovery mode so that an older firmware can be flashed
firmware-recovery: vr2jb-install
	@. "$(CURDIR)/lib.sh"
	step "Enter recovery mode (for downgrading)"
	require_headset_idle
	danger_banner "put the headset into recovery mode (vr2jb downgrade)"
	echo "vr2jb first prints its instructions. Read them before pressing the power button –"
	echo "the headset has to be unplugged right after each crash, and the timing matters."
	echo
	cd "$(VR2JB_DIR)"
	./vr2jb downgrade
	echo "Then flash firmware 6.00:"
	echo "  make firmware-flash FIRMWARE=/path/to/HMD2_FIRMWARE_V06_00.CUP"

firmware-flash: updater-install
	@. "$(CURDIR)/lib.sh"
	step "Flash firmware"
	[ -n "$(FIRMWARE)" ] || die "Usage: make firmware-flash FIRMWARE=/path/to/firmware.CUP"
	[ -f "$(FIRMWARE)" ] || die "$(FIRMWARE) not found"
	require_headset_idle
	danger_banner "flash $(notdir $(FIRMWARE)) to the headset"
	echo "PSVR2Updater shows the file's firmware version and asks once more."
	"$(UPDATER_DIR)/PSVR2Updater" "$(abspath $(FIRMWARE))"

# vr2jb uploads busybox, patcher and vr2bridge from its own directory
jailbreak: vr2jb-install
	@. "$(CURDIR)/lib.sh"
	step "Jailbreak"
	require_headset_idle
	danger_banner "jailbreak the headset (vr2jb)"
	cd "$(VR2JB_DIR)"
	./vr2jb
	echo "Check that the output above reports success, then start SteamVR."
	echo "The jailbreak is lost when the headset powers off – run 'make jailbreak' again then."

# Remove SteamVR's "disabled"/"blocked by safe mode" flags for the PSVR2 driver
unblock-driver:
	@. "$(CURDIR)/lib.sh"
	step "Re-enable PSVR2 driver in steamvr.vrsettings"
	pgrep -x vrserver >/dev/null && die "SteamVR is running – close it first"
	[ -f "$(VRSETTINGS)" ] || die "$(VRSETTINGS) missing – start SteamVR once"
	backup="$(VRSETTINGS).bak-$$(date +%Y%m%d-%H%M%S)"
	cp "$(VRSETTINGS)" "$$backup"
	jq --indent 3 'if .driver_playstation_vr2 then .driver_playstation_vr2 |= (del(.blocked_by_safe_mode) | .enable = true) else . end' \
	  "$$backup" > "$(VRSETTINGS)"
	ok "PSVR2 driver enabled (backup: $$backup)"

steamvr-settings:
	@. "$(CURDIR)/lib.sh"
	step "Update steamvr.vrsettings"
	pgrep -x vrserver >/dev/null && die "SteamVR is running – close it first"
	[ -f "$(VRSETTINGS)" ] || die "$(VRSETTINGS) missing – start SteamVR once"
	backup="$(VRSETTINGS).bak-$$(date +%Y%m%d-%H%M%S)"
	cp "$(VRSETTINGS)" "$$backup"
	jq --indent 3 '.steamvr.enableLinuxVulkanAsync = true | .steamvr.useFacetRenderer = true' \
	  "$$backup" > "$(VRSETTINGS)"
	ok "enableLinuxVulkanAsync, useFacetRenderer set (backup: $$backup)"

# --- Status ---------------------------------------------------------------------------

status:
	@. "$(CURDIR)/lib.sh"
	step "Installation"
	if [ -f "$(IGNITION_DIR)/VERSION" ]; then ok "Ignition $$(cat "$(IGNITION_DIR)/VERSION") in $(IGNITION_DIR)"
	else warn "Ignition not installed in $(IGNITION_DIR)"; fi
	if [ -f "$(LINUX64)/ignition.json" ]; then ok "Ignition shim in bin/linux64"
	else warn "Ignition shim not set up (make driver)"; fi
	if [ -f "$(WIN64)/.psvr2tk-manifest" ]; then
	  if (cd "$(WIN64)" && sha256sum -c --quiet .psvr2tk-manifest >/dev/null 2>&1); then
	    ok "PSVR2Toolkit $$(cat "$(WIN64)/.psvr2tk-version" 2>/dev/null) intact"
	  else warn "PSVR2Toolkit files changed (Steam update?) – run make reapply"; fi
	else warn "PSVR2Toolkit not installed (make psvr2tk)"; fi
	if [ -f "$(VRPATHS)" ] && $(DRIVER_REGISTERED); then ok "Registered with SteamVR"
	else warn "Not registered with SteamVR (make register)"; fi
	[ -f "$(UDEV_RULE)" ] && ok "xr-hardware udev rules" || warn "xr-hardware udev rules missing (make xr-hardware)"
	[ -f "$(VK_LAYER)" ] && ok "SteamVRLinuxFixes" || warn "SteamVRLinuxFixes missing (make linux-fixes)"
	[ -f "$(VRSETTINGS)" ] && ok "SteamVR has been started before" || warn "SteamVR has never been started"
	if [ -f "$(PLAYAREA_DIR)/VERSION" ]; then ok "PSVR2Toolkit.UnitySetup $$(cat "$(PLAYAREA_DIR)/VERSION") (make playarea)"
	else warn "PSVR2Toolkit.UnitySetup not installed – run make playarea to set up the play area"; fi
	for t in "$(VR2JB_DIR)|vr2jb" "$(UPDATER_DIR)|PSVR2Updater"; do
	  [ -f "$${t%%|*}/VERSION" ] && ok "$${t#*|} $$(cat "$${t%%|*}/VERSION") (optional)"
	done
	true
	step "Headset"
	check_headset_usb
	check_headset_display
	step "Last SteamVR run"
	check_driver_blocked "$(VRSETTINGS)"
	check_vrserver_log "$(VRLOGS)"

# --- Uninstall -------------------------------------------------------------------------

uninstall: unregister uninstall-psvr2tk uninstall-driver uninstall-ignition uninstall-playarea \
           uninstall-jailbreak

uninstall-all: uninstall uninstall-xr-hardware uninstall-linux-fixes

unregister:
	@. "$(CURDIR)/lib.sh"
	step "Unregister driver from SteamVR"
	if [ -x "$(LINUX64)/driver_uninstall.sh" ]; then "$(LINUX64)/driver_uninstall.sh"
	else warn "driver_uninstall.sh not present – skipped"; fi

uninstall-psvr2tk:
	@. "$(CURDIR)/lib.sh"
	step "Remove PSVR2Toolkit"
	cd "$(WIN64)" 2>/dev/null && [ -f .psvr2tk-manifest ] || { warn "No toolkit manifest – skipped"; exit 0; }
	dll=driver_playstation_vr2.dll orig=driver_playstation_vr2_orig.dll
	awk '{ print $$2 }' .psvr2tk-manifest | grep -vx "$$dll" | xargs -r rm -f --
	if [ -f "$$orig" ] && grep -q "^$$(sha256sum "$$dll" | cut -d' ' -f1)  $$dll$$" .psvr2tk-manifest; then
	  mv -f "$$orig" "$$dll"
	  ok "Sony's original restored"
	else
	  rm -f "$$orig"
	  warn "$$dll is not (or no longer) the toolkit DLL – kept, $$orig removed"
	fi
	rm -f .psvr2tk-manifest .psvr2tk-version

uninstall-driver:
	@. "$(CURDIR)/lib.sh"
	step "Remove Ignition shim from bin/linux64"
	[ -d "$(LINUX64)" ] || { warn "not present"; exit 0; }
	name=$$(jq -r .name "$(PLUGIN_DIR)/driver.vrdrivermanifest")
	cd "$(LINUX64)"
	rm -f ignition.json proton launch_serverhelper.sh driver_install.sh driver_uninstall.sh \
	  wine_hidraw.reg "driver_$$name.so"
	cd .. && rmdir linux64 2>/dev/null || warn "$(LINUX64) contains other files – not deleted"
	ok "removed"

uninstall-ignition:
	@. "$(CURDIR)/lib.sh"
	step "Remove $(IGNITION_DIR)"
	case "$(IGNITION_DIR)" in ""|/|/opt|/usr|"$(HOME)") die "IGNITION_DIR='$(IGNITION_DIR)' is not allowed";; esac
	[ -f "$(IGNITION_DIR)/install_ignition.sh" ] || { warn "not present"; exit 0; }
	$(SUDO) rm -rf "$(IGNITION_DIR)"
	ok "removed"

uninstall-playarea:
	@. "$(CURDIR)/lib.sh"
	step "Remove $(PLAYAREA_DIR)"
	[ -f "$(PLAYAREA_DIR)/$(PLAYAREA_BIN)" ] || { warn "not present"; exit 0; }
	rm -rf "$(PLAYAREA_DIR)"
	ok "removed (your saved play area is kept in SteamVR's config)"

uninstall-jailbreak:
	@. "$(CURDIR)/lib.sh"
	step "Remove vr2jb and PSVR2Updater"
	for d in "$(VR2JB_DIR)" "$(UPDATER_DIR)"; do
	  [ -f "$$d/VERSION" ] && rm -rf "$$d" && ok "$$d removed" || true
	done

uninstall-xr-hardware:
	@. "$(CURDIR)/lib.sh"
	$(SUDO) rm -f "$(UDEV_RULE)"
	$(SUDO) udevadm control --reload-rules
	ok "$(UDEV_RULE) removed"

uninstall-linux-fixes:
	@. "$(CURDIR)/lib.sh"
	$(SUDO) rm -f "$(VK_LAYER)" "$(VK_LAYER_LIB)"
	ok "SteamVRLinuxFixes removed"
