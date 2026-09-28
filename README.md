# PSVR2 Linux Companion

Installer and helpers for running PlayStation VR2 on Linux with Ignition and PSVR2Toolkit.

A Makefile that automates the
[PSVR2Toolkit Linux guide](https://github.com/BnuuySolutions/PSVR2Toolkit/wiki/Linux-support):
it installs [Ignition](https://github.com/BnuuySolutions/Ignition) (runs the Windows PSVR2
SteamVR driver under Proton), the experimental
[PSVR2Toolkit](https://github.com/BnuuySolutions/PSVR2Toolkit) build,
[SteamVRLinuxFixes](https://github.com/BnuuySolutions/SteamVRLinuxFixes) and the
[xr-hardware](https://gitlab.freedesktop.org/monado/utilities/xr-hardware) udev rules.

Releases are downloaded from GitHub on every run (latest by default), verified against the
sha256 digest published by GitHub and deleted afterwards. This repository contains no binaries.

> Ignition is built with CMake but ships no `make install` – installing it means extracting
> the release to `/opt/ignition` and running its shell scripts. That is what this Makefile does,
> plus the surrounding steps from the guide.

## Requirements

**Hardware**
- PlayStation VR2 with the Sony **PlayStation VR2 PC adapter** (with its power supply connected)
- A GPU with a free **DisplayPort** output
- A free **USB 3 port** – ideally a rear port directly on the mainboard. Hubs, extension cables
  and front-panel ports often make the headset connect at USB 2 speed and drop out.
- Headset firmware 5.00 or newer. The official PlayStation VR2 App cannot update it on Linux;
  `make firmware` shows the version and `make firmware-flash` updates it (see the
  [jailbreak section](#optional-jailbreak-vr2jb) for the warnings).

**Software**
- Steam, the native package – **not** the Flatpak
- Installed in Steam, all in the **main Steam library** (not on a second drive):
  - [SteamVR](https://store.steampowered.com/app/250820/SteamVR/) (stable, not beta)
  - [PlayStation VR2 App](https://store.steampowered.com/app/2580190/PlayStationVR2_App/)
  - Proton Experimental (Library → Tools)
- `curl`, `unzip`, `jq` – e.g. `sudo apt install curl unzip jq`

> **Note:** You never launch the PlayStation VR2 App itself – Sony's apps do not run on Linux.
> It is only installed because it contains the SteamVR driver that Ignition loads.

## Installation

1. Install the requirements above.
2. Start **SteamVR** once and close it again (this creates its config files).
3. Run:

   ```bash
   git clone https://github.com/trigrab/psvr2-linux-companion.git && cd psvr2-linux-companion
   make check      # verifies all requirements
   make install    # asks for your sudo password for /opt, /etc/udev and /usr
   ```

   Run `make` as your normal user, not with `sudo` – it calls `sudo` itself where needed.
4. Connect the PC adapter – DisplayPort cable to the GPU, USB cable to a USB 3 port, power supply
   plugged in – and connect the headset to the adapter. `make status` should show the headset on
   USB (5000 Mbit/s) and the headset display on a GPU output.
5. Start SteamVR. Headset and Sense controllers should turn green.
6. Set up your play area for 6DoF tracking: `make playarea` (see [Play area](#play-area)).

Optional: with SteamVR closed, `make steamvr-settings` enables `enableLinuxVulkanAsync` and
`useFacetRenderer` in `steamvr.vrsettings` (as recommended by the guide; a backup is created).

### What `make install` does

| Step          | Action                                                                         |
|---------------|--------------------------------------------------------------------------------|
| `check`       | Tools, Steam, SteamVR / PSVR2 App / Proton in the main library, SteamVR started once |
| `xr-hardware` | udev rules → `/etc/udev/rules.d/70-xrhardware.rules` (headset + controller access) |
| `linux-fixes` | SteamVRLinuxFixes Vulkan layer → `/usr` (refresh rates, latency, Mesa fixes)   |
| `ignition`    | Ignition release → `/opt/ignition`                                            |
| `driver`      | `install_ignition.sh` → creates `SteamVR_Plug-In/bin/linux64`                  |
| `psvr2tk`     | Sony's DLL → `driver_playstation_vr2_orig.dll`, toolkit → `bin/win64`          |
| `register`    | `driver_install.sh` → adds the driver to `~/.config/openvr/openvrpaths.vrpath` |

Every step can also be run on its own, e.g. `make psvr2tk`. `make help` lists all targets.

## Play area

Without the PlayStation VR2 App, the play area is set up with
[PSVR2Toolkit.UnitySetup](https://github.com/BnuuySolutions/PSVR2Toolkit.UnitySetup), a native
Linux OpenVR app that talks to the PSVR2 driver directly. SteamVR's own room setup does not
apply – the driver keeps its play area in `~/.steam/steam/config/playstation_vr2/`.

```bash
make playarea
```

downloads the tool to `~/.local/share/PSVR2Toolkit.UnitySetup` (or updates it) and starts it.
SteamVR must be running with the headset shown green. In the headset you see your room through
the cameras:

1. **Look at your surroundings** until the map score is good – this builds the tracking map.
2. **Draw the play area** on the floor with the controllers (add, subtract, move points).
3. **Save** – the button is only enabled once tracking works.

To start it from inside VR instead, register it with SteamVR once (SteamVR closed):

```bash
make playarea-register
```

It then shows up as *PSVR2 Play Area Setup* in SteamVR's app library, next to your non-Steam
apps. Updates via `make playarea` keep the registration; `make uninstall` removes it.

SteamVR's own *Room Setup* menu entry still opens Valve's tool – SteamVR offers no way to replace
it. Use *PSVR2 Play Area Setup* instead; Valve's room setup does not apply to the PSVR2.

The tool also calibrates eye tracking and helps with lens adjustment. If tracking gets worse
later, use *Refine map* or *Clear SLAM map* – both keep the drawn play area.

## Optional: Jailbreak (vr2jb)

> [!CAUTION]
> **Jailbreaking or flashing firmware can brick your headset.** Both are unofficial.
> Neither this installer nor the authors of [vr2jb](https://github.com/BnuuySolutions/vr2jb)
> and [PSVR2Updater](https://github.com/RealSupremium/PSVR2Updater) take any responsibility.
> Read the [jailbreak guide](https://github.com/BnuuySolutions/PSVR2Toolkit/wiki/Jailbreaking-your-headset)
> in full before you start. Everything above works **without** a jailbreak.

The jailbreak unlocks **headset vibration** and the **raw eye tracking camera images**. You do
not need it for eye tracking as such: gaze direction and per-eye openness (blinking) are provided
by Sony's driver and work without a jailbreak – that is what PSVR2Toolkit.UnitySetup and the
[VRCFaceTracking module](https://github.com/BnuuySolutions/PSVR2Toolkit.VRCFT) use. The camera
images are only needed by software that analyses them itself, such as
[Baballonia](https://github.com/Project-Babble/Baballonia) with the
[PSVR2Toolkit.Baballonia](https://github.com/BnuuySolutions/PSVR2Toolkit.Baballonia) module
(finer eye expressions in VRChat, Resonite and ChilloutVR).

The jailbreak has three limits:

- It only works on **firmware 6.00**.
- It is **not persistent**: after every headset power-off (red LED) you have to run it again,
  before starting SteamVR.
- Using the headset on a PS5 updates the firmware. A newer firmware can make downgrading
  impossible, so avoid firmware updates if you want to keep the jailbreak.

The targets below download vr2jb and PSVR2Updater to `~/.local/share` (verified against GitHub's
sha256). Before anything that writes to the headset they show a red warning banner and ask for
confirmation, on every run. SteamVR must be closed and the headset connected.

### 1. Check the firmware

```bash
make firmware
```

Reads the firmware and recovery version (nothing is written) and tells you what to do next:

| Result | Next step |
|--------|-----------|
| Firmware 6.00 | Go to step 3. |
| Older than 6.00 | Update to 6.00 (step 2, flash only). |
| Newer than 6.00 | Downgrade: enter recovery mode, then flash 6.00 (step 2). |
| Recovery version 6.10 or newer | Downgrading is impossible – no jailbreak on this headset. |

### 2. Downgrade or update to 6.00

Get the firmware 6.00 file `HMD2_FIRMWARE_V06_00.CUP` via the link in the
[jailbreak guide](https://github.com/BnuuySolutions/PSVR2Toolkit/wiki/Jailbreaking-your-headset#prerequisites).
This installer does not download it: there is no published checksum to verify it against, and a
wrong file can brick the headset.

```bash
make firmware-recovery    # only when downgrading: enter recovery mode (see below)
make firmware-flash FIRMWARE=~/Downloads/HMD2_FIRMWARE_V06_00.CUP
make firmware             # should now report firmware 6.00
```

`make firmware-recovery` crashes the headset repeatedly until it falls back to recovery mode.
vr2jb prints its instructions first – follow them exactly: after each crash you unplug the
headset, plug it back in and press the power button. This can take 15 or more rounds.

Do not disconnect the headset or turn off the PC while flashing. PSVR2Updater shows the file's
firmware version and asks once more before it writes anything.

### 3. Jailbreak – after every headset power-on

```bash
make jailbreak
```

Check that the output reports success, then start SteamVR.

## Checking your setup

```bash
make status
```

shows the installation state, whether the headset is connected at USB 3 speed with the right
permissions, whether its display is visible on a GPU output, and whether the last SteamVR run
loaded the driver through Ignition (including safe-mode and USB errors).

`make versions` shows which releases `make install` would use.

## Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| PlayStation VR2 App does not start | Expected – it is not needed, see the note above. Start SteamVR instead. |
| `make status`: *connected at only 12/480 Mbit/s* or *not found on USB* | Move the adapter's USB cable to a rear USB 3 port on the mainboard, no hub/extension. Check the adapter's power supply. |
| `make status`: *USB transfers to the headset failed* | Same – unstable USB connection. |
| SteamVR: *"your headset might not be connected or your desktop environment might not support VR"* | The headset display is not visible to the GPU. Connect the adapter's DisplayPort cable directly to the GPU; `make status` shows *PlayStation VR2 display connected*. |
| SteamVR crashed and restarted in safe mode | Close SteamVR, wait ~10 seconds, start it again. If `make status` reports the driver as disabled, run `make unblock-driver` with SteamVR closed. |
| PlayStation VR2 is not listed under *Manage Add-ons* | Expected – the driver is registered through Ignition, not as a regular add-on. Use `make status` to check it. |
| `make status`: *did not load the PSVR2 driver through Ignition* | Run `make status` and fix any warnings in the installation section; check `~/.steam/steam/logs/vrserver.txt`. |
| No positional tracking, only rotation | No play area set up yet – `make playarea`. |
| `make check`: *must be in the main library* | Move the app in Steam: Properties → Installed Files → Move install folder. |
| Left controller not working | xr-hardware rules from a distro package are outdated – `make xr-hardware`, then reconnect. |
| Controllers not showing up | Disable *Gamepad Support* in SteamVR → Settings → Startup/Shutdown → Manage Add-ons; reconnect the controllers. |
| SteamVR error 497 | Mesa 25.3.0–25.3.1 is broken (`vulkaninfo --summary`), or your compositor lacks DRM leasing. |
| No audio | Set the GPU's audio output profile to *HDMI 2* (sometimes *HDMI 6*). |
| Poor controller tracking | BlueZ limitation, see the [guide](https://github.com/BnuuySolutions/PSVR2Toolkit/wiki/Linux-support#bad-controller-tracking). |

To test Proton on its own, run `./proton run cmd` in
`~/.steam/steam/steamapps/common/PlayStation VR2 App/SteamVR_Plug-In/bin/linux64/` – a
command prompt window should open.

Known limitations of Ignition (Room View, Sony apps, controller poll rate) are listed in the
[guide](https://github.com/BnuuySolutions/PSVR2Toolkit/wiki/Linux-support#missing-or-restricted-features).

## Updating

- **Steam updated the PlayStation VR2 App:** `make status` reports changed toolkit files →
  `make reapply`. The new Sony DLL is kept as the new original.
- **New Ignition / PSVR2Toolkit release:** run `make install` again (or just `make ignition` /
  `make psvr2tk`). `make playarea` updates the play area tool by itself.
- **Specific version:** `make install IGNITION_VERSION=v1.1.0 PSVR2TK_VERSION=v1.0.0-experimental-2`

## Uninstalling

```bash
make uninstall       # unregister driver, remove toolkit + shim + /opt/ignition + play area tool,
                     # restore Sony's DLL
make uninstall-all   # additionally remove the udev rules and the Vulkan layer
```

`make uninstall` also removes vr2jb and PSVR2Updater from `~/.local/share`. It does not change
the headset's firmware. The Proton prefix used by Ignition (`~/.proton`) and your saved play area are left in place.

## Differences from the upstream guide

- `PROTONVERSION` is pinned to `Proton - Experimental` in `bin/linux64/launch_serverhelper.sh`.
  Upstream's `proton` script otherwise picks the "newest" Proton by version sort, which is not
  necessarily Experimental. Disable with `make driver PROTON_VERSION=`.
- `bin/win64/.psvr2tk-manifest` records the installed toolkit files, so running `make psvr2tk`
  again (or updating the toolkit) never overwrites Sony's original DLL.

## Configuration

All variables can be overridden on the command line:

| Variable | Default |
|----------|---------|
| `IGNITION_VERSION`, `PSVR2TK_VERSION`, `SVLF_VERSION`, `PLAYAREA_VERSION` | `latest` |
| `IGNITION_DIR` | `/opt/ignition` (must be reachable from the Steam Linux Runtime) |
| `STEAM_DIR` | `~/.steam/steam`, or `~/.local/share/Steam` |
| `PLUGIN_DIR` | `$STEAM_DIR/steamapps/common/PlayStation VR2 App/SteamVR_Plug-In` |
| `PLAYAREA_DIR` | `~/.local/share/PSVR2Toolkit.UnitySetup` |
| `VR2JB_VERSION`, `UPDATER_VERSION` | `latest` |
| `VR2JB_DIR`, `UPDATER_DIR` | `~/.local/share/vr2jb`, `~/.local/share/PSVR2Updater` |
| `PROTON_VERSION` | `Proton - Experimental` |
| `SUDO` | `sudo` |

## License

[MIT](LICENSE). This repository only contains the installer; Ignition, PSVR2Toolkit,
PSVR2Toolkit.UnitySetup, vr2jb, PSVR2Updater, SteamVRLinuxFixes and xr-hardware are downloaded from their projects and are covered by
their own licenses.
