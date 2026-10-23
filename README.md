# PiZERO Speakers

Turn a Raspberry Pi Zero W (or Zero 2 W) and a pair of USB speakers into a network speaker
that phones, PCs and TVs can play to:

| Protocol | Who can use it | How |
|---|---|---|
| **Spotify Connect** | Any Spotify app (phone, PC, TV), Premium account | Devices icon → *PiZERO Speakers*. The Pi streams from Spotify itself. |
| **AirPlay** (classic AirPlay 1) | iPhone/iPad/Mac natively; Linux via PipeWire; Windows via e.g. TuneBlade; Android via e.g. AirMusic | Pick *PiZERO Speakers* as audio output |
| **UPnP/DLNA renderer** | Media apps such as BubbleUPnP, Kodi, VLC, Windows "Cast to device" | Pick *PiZERO Speakers* as renderer |
| **Bluetooth A2DP** | Devices you explicitly paired (e.g. a TV) | Locked by default: invisible to neighbours, pairing only during a short window you open |

All sources play through one mixer (PipeWire) into the USB audio device, so they can even play at
the same time (they are mixed, nothing pauses automatically).

Everything is installed and maintained from your PC over SSH with one script
(`scripts/speaker.sh`), and the Pi is built to recover from power cuts, Wi-Fi outages and crashes on
its own.

---

## 1. What you need

- **Raspberry Pi Zero W** or **Zero 2 W**, power supply (micro-USB, 5 V / 1.2 A or more), micro-SD card (8 GB+)
- **USB speakers or any USB audio device / USB DAC**, plus a **micro-USB OTG adapter**
  (micro-USB male → USB-A female). Tested with Audioengine A2+ (built-in USB DAC).
- A Linux PC (or macOS/WSL with bash) with `ssh`, `python3`, `curl`, `sha256sum`, `tar`;
  optional: `avahi-utils` (finding the Pi by name), `binutils` (`readelf`, sanity check of the Spotify binary)
- A **2.4 GHz** Wi-Fi network: the Zero W and Zero 2 W cannot use 5 GHz

The Zero has two micro-USB ports: **PWR** (edge of the board) is power only; the speakers go into
the one labelled **USB** (middle), through the OTG adapter.

## 2. Prepare the SD card

Use [Raspberry Pi Imager](https://www.raspberrypi.com/software/):

1. *Device*: Raspberry Pi Zero (W) or Zero 2 W.
2. *OS*: **Raspberry Pi OS Lite (32-bit)** (*Raspberry Pi OS (other)*). Lite is strongly
   recommended: the desktop costs a lot of the Zero's single CPU core. The scripts also work on a
   desktop image (they switch it to console boot), and on 64-bit Raspberry Pi OS on a Zero 2 W.
3. *Edit settings* (OS customisation):
   - hostname, e.g. `raspberrypi`
   - username and password
   - Wi-Fi name and password, **Wi-Fi country**
   - *Services*: enable SSH, ideally "allow public-key authentication only" with your PC's public key
4. Write the card, put it in the Pi, plug in power.

The first boot takes a few minutes (the file system is expanded, settings applied).

**Requires Raspberry Pi OS based on Debian 13 "Trixie" or newer** (`setup` checks this). The older
"Bookworm" release is not supported (different WirePlumber and package names).

### The Pi does not show up on the network?

- Check your router's device list for a device whose MAC address starts with `b8:27:eb`, `dc:a6:32`,
  `e4:5f:01`, `d8:3a:dd`, `28:cd:c1`, `2c:cf:67` or `88:a2:9e` (Raspberry Pi). If it is listed
  with no IP address (`0.0.0.0`), it found the Wi-Fi but the password is wrong.
- Fix the Wi-Fi on the card from your PC: power off the Pi, put the card in a card reader (most
  desktops mount it automatically, or `udisksctl mount -b /dev/sdX2`), then

  ```sh
  sudo python3 scripts/set-wifi.py --ssid "Your Network"     # asks for the password (hidden)
  ```

  It adds the network to the card's NetworkManager config (password stored as a hash, never
  printed). `--replace-all` removes other stored networks, `--hidden` for hidden networks.
- Signal: a Zero W inside a metal case has a weak signal. Keep it near the router or out of the case.

## 3. Configure this repository

```sh
git clone <this repo> PiZERO && cd PiZERO
cp config.example.env config.env      # gitignored; edit it
ssh-copy-id <user>@raspberrypi.local  # only if you did not add your key in the Imager
```

`config.env` settings (environment variables override them):

| Setting | Default | Meaning |
|---|---|---|
| `PI_HOST` | `raspberrypi.local` | Hostname or IP of the Pi |
| `PI_USER` | ssh's default | SSH user on the Pi (the one created in the Imager) |
| `SPEAKER_NAME` | `PiZERO Speakers` | Name shown in AirPlay, Spotify, DLNA and Bluetooth |
| `BT_MODE_DEFAULT` | `locked` | Bluetooth mode on first install: `locked` or `open` |
| `SPEAKER_MODE_DEFAULT` | `all` | Speaker mode on first install: `all`, `bluetooth` or `network` (see [Speaker modes](#speaker-modes-bluetooth-only-network-only-both)) |

The SSH user needs passwordless `sudo` (the Imager's default user has it).

## 4. Install

```sh
scripts/speaker.sh setup
```

This takes 10-30 minutes on a Zero W (package installs are slow) and can be re-run at any time;
it only changes what differs. It:

- switches the Pi to console boot and keeps your user's audio session running without a login
- installs PipeWire/WirePlumber (+ rtkit for real-time audio), shairport-sync, gmediarender,
  BlueZ, Avahi and the Spotify Connect receiver
  ([go-librespot](https://github.com/devgianlu/go-librespot), downloaded as a pinned,
  checksum-verified release by `scripts/build-spotify-connect.sh`; ARMv6 build for 32-bit OS,
  arm64 build for 64-bit OS)
- deploys the configuration in `pi/` (the speaker name is filled in from `config.env`)
- applies the recovery settings below, applies the persisted speaker mode and starts the
  services that mode allows

Check the result:

```sh
scripts/speaker.sh status
```

Then plug the speakers in (any time; hot-plugging works). The first USB audio device becomes the
default output automatically, at 100 % volume (use the senders' volume and the speakers' knob).

## 5. Connecting devices

### Spotify (phone, PC, TV)
In any Spotify app on the same network: devices icon → **PiZERO Speakers**. No login on the Pi is
needed; the app hands over the session. The phone/PC is then only a remote control.

### Linux PC (PipeWire)
```sh
scripts/linux-pc.sh enable        # AirPlay buffer 500 ms (default)
scripts/linux-pc.sh enable 250    # lower delay, less tolerant of Wi-Fi hiccups
scripts/linux-pc.sh status
scripts/linux-pc.sh disable
```
*PiZERO Speakers* then appears as a normal sound output; select it in your sound settings.
Discovery runs as a small user service (`pizero-airplay`) next to PipeWire, so enabling, disabling
or changing the buffer never restarts PipeWire. A timer (`pizero-airplay-heal`) re-adds the output
within a minute if the Pi was offline (it never interrupts running playback). The script must stay
where it was when you ran `enable` (the timer calls it).

AirPlay always buffers: expect roughly the buffer plus ~250 ms of PipeWire's own latency. For
video, most players compensate automatically. For lowest latency (games), see *Low latency* below.

PipeWire tip: avoid `systemctl --user restart pipewire` on a running desktop. Desktop components
(e.g. the COSMIC or GNOME audio applet) may not reconnect until you log out and back in.

### Windows PC
- Spotify desktop app: Spotify Connect (above).
- All PC sound: an AirPlay sender such as TuneBlade (free) → *PiZERO Speakers*.
- Media files: Explorer → right-click → *Cast to device* (DLNA).

### Android phone
- Spotify: Spotify Connect.
- Other apps: an AirPlay sender app (e.g. AirMusic) or a DLNA app (e.g. BubbleUPnP).
- Bluetooth works too if you pair the phone (see below), but the lock keeps unknown devices out.
- Android's built-in "cast" (Google Cast) is not supported: Cast receivers require Google certification.

### iPhone, iPad, Mac
AirPlay: pick *PiZERO Speakers* in the AirPlay menu.

### TV or other Bluetooth device
Bluetooth is **locked** by default: the Pi is invisible and refuses unknown devices, so neighbours
cannot connect. To pair a device once:

```sh
scripts/speaker.sh bt-pair 180     # opens a 3-minute pairing window
```

then on the device search for Bluetooth speakers and choose *PiZERO Speakers*. The window closes by
itself (the timer runs on the Pi, even if your SSH session drops). Paired devices are trusted and
reconnect automatically while locked.

```sh
scripts/speaker.sh bt-devices          # list paired devices
scripts/speaker.sh bt-forget AA:BB:..  # remove one
scripts/speaker.sh bt-mode open        # always discoverable/pairable (not recommended)
scripts/speaker.sh bt-mode locked
```

If a paired device was reset or lost its pairing, it cannot simply pair again while locked (this
protects against devices impersonating it): run `bt-forget` for it, then `bt-pair` again.

Some TVs keep playing through their own speakers after pairing; select the Bluetooth speaker as
the TV's sound output in its sound settings.

### Speaker modes: Bluetooth only, network only, both
All four protocols run by default. On a Zero W the single CPU core and the shared
Wi-Fi/Bluetooth radio are the scarce resources: a connected Bluetooth device alone costs ~25 % CPU,
and Wi-Fi and Bluetooth time-share the same antenna. If you only ever use one kind of source, the
speaker mode turns the other side off:

| Mode | Network receivers | Bluetooth | Frees |
|---|---|---|---|
| `all` (default) | AirPlay, DLNA, Spotify | on | — |
| `bluetooth` | off (disabled and stopped) | on | the receiver processes and their CPU time; no audio traffic crosses Wi-Fi, so Bluetooth does not compete for the shared radio |
| `network` | on | off (disabled, stopped, radio soft-blocked) | the Bluetooth stack and the ~25 % CPU a connected device costs |

```sh
scripts/speaker.sh mode                # print the current mode
scripts/speaker.sh mode bluetooth
scripts/speaker.sh mode network
scripts/speaker.sh mode all
```

Wi-Fi stays on in `bluetooth` mode: it is how you reach the Pi (SSH, `status`, updates) and the
watchdog that recovers the Pi depends on it. With the receivers stopped no audio crosses Wi-Fi, so
Bluetooth no longer competes with AirPlay/DLNA streaming on the shared radio; only the idle Wi-Fi
connection remains. In `network` mode the adapter is soft-blocked with `rfkill`, so nothing can
power it by accident.

The mode is stored in `/etc/pizero/mode` on the Pi and survives reboots and
`setup`/`update`/`reinstall` (like `/etc/pizero/bluetooth-mode`, it is only written when absent; a
fresh install starts with `SPEAKER_MODE_DEFAULT`). Unit enablement makes it persistent, and a small
one-shot unit re-applies the radio state before `bluetoothd` starts. Switching interrupts whatever
is playing; switching back enables and starts the receivers again. The `bt-*` commands refuse to
run in `network` mode because there is no Bluetooth stack.

### Low latency: analog input
Network audio always has some delay. Many powered speakers (e.g. Audioengine A2+) have an analog
input that is mixed with USB: connect the PC's line-out to it and switch between the analog output
(no delay) and *PiZERO Speakers* (network) on the PC.

## 6. Day-to-day operation

| Command | What it does |
|---|---|
| `scripts/speaker.sh status` | Speaker mode, services, Bluetooth mode/devices, output device, network, load, memory |
| `scripts/speaker.sh restart` | Restart the speaker services |
| `scripts/speaker.sh mode [M]` | Speaker mode: `all` (default), `bluetooth` or `network`; no argument prints it |
| `scripts/speaker.sh logs [service]` | Recent logs (e.g. `shairport-sync`, `spotify-connect`, `gmediarender`) |
| `scripts/speaker.sh update` | `apt full-upgrade`, refresh Spotify binary, redeploy config, restart |
| `scripts/speaker.sh reinstall` | Reinstall all speaker packages + Spotify binary, redeploy, restart |
| `scripts/speaker.sh setup` | Full (idempotent) install, e.g. after changing `config.env` or `pi/` |
| `scripts/speaker.sh protect on\|off\|status` | Read-only root file system (see below); reboots |

The Spotify receiver version is pinned in `scripts/build-spotify-connect.sh`. To upgrade, change the
version and checksums there, then run `scripts/speaker.sh update`.

## 7. Self-recovery

| Failure | What happens |
|---|---|
| A service crashes or hangs | systemd restarts it, forever (`Restart=always`, no start limit) |
| The audio server restarts | AirPlay, Spotify and DLNA receivers restart with it |
| Wi-Fi or router outage | Wi-Fi retries indefinitely; a watchdog checks the gateway every minute: Wi-Fi off/on after 2 min down, restart NetworkManager (and the Wi-Fi driver) after 10 min, reboot after 20 min (only if the Pi has been up 30+ min, so no reboot loops). Spotify reconnects when the network returns |
| System hang | Hardware watchdog reboots after 15 s |
| Kernel crash | Automatic reboot after 10 s |
| Power cut | Logs are kept in RAM, automatic apt timers are off, the file system is repaired at boot (`fsck.repair=yes`); everything starts without a login |
| Reboot or power cut in `bluetooth`/`network` mode | The mode is applied again at boot (`pizero-mode.service`, ordered before `bluetoothd`): services that the mode disables stay off and the Bluetooth radio stays soft-blocked in `network` mode |
| USB speakers unplugged/replugged | The output comes back as default automatically |

**Protect mode** (`scripts/speaker.sh protect on`) makes the root file system read-only
(Raspberry Pi OS overlay): power cuts cannot damage it, but all changes are lost at reboot.
Recommended once everything is set up (and your Bluetooth devices are paired).
`setup`, `update`, `reinstall`, `mode` (when setting one) and the `bt-*` commands refuse to run
while it is on; run `protect off` first.

## 8. Troubleshooting

- **Speaker not visible in apps**: `scripts/speaker.sh status`. Phones and PCs must be on the same
  network (guest Wi-Fi networks usually isolate devices).
- **No sound**: is the USB device detected? `status` shows the default output; it should be the USB
  device, not *Dummy Output*. Check the OTG adapter and the **USB** (not PWR) port.
- **Choppy sound**: usually weak Wi-Fi. Move the Pi closer to the router or out of a metal case.
  Bluetooth and Wi-Fi share one radio on the Zero, so heavy Bluetooth use can affect Wi-Fi.
- **Spotify device disappears briefly**: the receiver restarts after network changes; it reappears
  within seconds.

### Known limitations
- While a Bluetooth device is connected, WirePlumber uses ~25 % of the Zero W's CPU, even when
  idle. Playback is unaffected (no dropouts measured), but there is less headroom; forget unused
  Bluetooth devices.
- Bluetooth volume buttons of the sender do not change the Pi's volume (no AVRCP absolute volume).
- AirPlay 2 is not supported (AirPlay 1 only); Apple devices and common senders still work.

## Repository layout

```
scripts/speaker.sh               install / operate the Pi (run on your PC)
scripts/build-spotify-connect.sh fetch the pinned Spotify Connect receiver (build/, gitignored)
scripts/linux-pc.sh              make AirPlay speakers outputs on a Linux PC (PipeWire)
scripts/set-wifi.py              fix Wi-Fi settings on a Pi SD card from a PC
config.example.env               settings template (copy to config.env)
pi/                              files deployed to the Pi, mirroring their paths
                                 (pi/home/USER = the SSH user's home; @SPEAKER_NAME@ etc. are filled in;
                                 pi/etc/pizero/mode and bluetooth-mode are only installed when absent)
```
