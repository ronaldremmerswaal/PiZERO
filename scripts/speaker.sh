#!/usr/bin/env bash
#
# PiZERO Speakers - install and operate a Raspberry Pi Zero / Zero 2 W as a
# network speaker (AirPlay, Bluetooth A2DP, Spotify Connect, UPnP/DLNA).
#
# Runs on your workstation and talks to the Pi over SSH. Configuration lives
# in config.env (see config.example.env); environment variables win.
#
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)

# --- configuration ----------------------------------------------------------

CONFIG_FILE=${PI_CONFIG:-$REPO_DIR/config.env}
_env_PI_HOST=${PI_HOST-}
_env_PI_USER=${PI_USER-}
_env_SPEAKER_NAME=${SPEAKER_NAME-}
_env_BT_MODE_DEFAULT=${BT_MODE_DEFAULT-}
if [[ -f $CONFIG_FILE ]]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
fi
PI_HOST_EXPLICIT=0
[[ -n ${PI_HOST-} ]] && PI_HOST_EXPLICIT=1
PI_HOST=${_env_PI_HOST:-${PI_HOST:-raspberrypi.local}}
PI_USER=${_env_PI_USER:-${PI_USER:-}}
SPEAKER_NAME=${_env_SPEAKER_NAME:-${SPEAKER_NAME:-PiZERO Speakers}}
BT_MODE_DEFAULT=${_env_BT_MODE_DEFAULT:-${BT_MODE_DEFAULT:-locked}}

die() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
say() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }

[[ -n $SPEAKER_NAME && $SPEAKER_NAME != *$'\n'* ]] ||
    die "SPEAKER_NAME must be a non-empty single line"
case $BT_MODE_DEFAULT in
    open | locked) ;;
    *) die "BT_MODE_DEFAULT must be 'open' or 'locked'" ;;
esac

# Runtime packages. Every entry is used by one of the speaker services.
PKGS=(
    bluez bluez-tools rfkill rtkit
    avahi-daemon dbus-user-session systemd-timesyncd
    pipewire pipewire-audio pipewire-pulse wireplumber pipewire-alsa libspa-0.2-bluetooth
    alsa-utils pulseaudio-utils
    shairport-sync gmediarender
    gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad
    gstreamer1.0-plugins-ugly gstreamer1.0-pulseaudio
    python3-dbus python3-gi
    libasound2t64 ca-certificates
)

APP_SERVICES=(shairport-sync gmediarender spotify-connect)
USER_SERVICES=(pipewire wireplumber pipewire-pulse "${APP_SERVICES[@]}")
SYSTEM_SERVICES=(bluetooth pizero-bt-agent avahi-daemon rtkit-daemon)
SYSTEM_TIMERS=(pizero-net-watchdog.timer)

SPOTIFY_BUILD="$SCRIPT_DIR/build-spotify-connect.sh"
SPOTIFY_UNIT="$REPO_DIR/pi/home/USER/.config/systemd/user/spotify-connect.service"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new)
SSH_TARGET=""
STAGE=""
GMEDIA_UUID=""

usage() {
    cat <<EOF
PiZERO Speakers - remote control for the Pi speaker (${PI_USER:+$PI_USER@}$PI_HOST)

Usage: $(basename "$0") <command>

Commands:
  setup        Full idempotent install: console boot, linger, packages, config,
               resilience settings, Spotify binary, all services enabled
  update       apt update + full-upgrade, refresh the Spotify binary, redeploy,
               restart
  reinstall    Reinstall all speaker packages and the Spotify binary, redeploy,
               restart
  status       Services, Bluetooth mode/devices, sink, network, load, RAM
  restart      Restart the speaker services (no package/config work)
  logs [S]     Recent journal for service S (default: all speaker services)
  bt-pair [S]  Open a pairing window for S seconds (default 120); the timeout
               runs on the Pi, then the persisted mode returns
  bt-mode M    Persist and apply Bluetooth mode: "locked" (default) or "open"
  bt-devices   List paired Bluetooth devices (MAC, name, trusted, connected)
  bt-forget M  Remove (forget) the paired device with MAC address M
  protect C    Read-only overlay root: "on", "off" or "status" (reboots)

Configuration:
  Copy config.example.env to config.env (gitignored) or export variables:
    PI_HOST          Pi hostname/IP (default raspberrypi.local, via mDNS)
    PI_USER          SSH user (default: ssh's own default / ~/.ssh/config)
    SPEAKER_NAME     advertised name (default "PiZERO Speakers")
    BT_MODE_DEFAULT  "locked" (default) or "open"

Examples:
  $(basename "$0") setup
  $(basename "$0") status
  $(basename "$0") bt-pair 120
  $(basename "$0") logs shairport-sync
EOF
}

# --- ssh plumbing -----------------------------------------------------------

resolve_host() {
    local host=$PI_HOST ip
    if getent hosts "$host" >/dev/null 2>&1; then
        printf '%s' "$host"
        return 0
    fi
    if command -v avahi-resolve >/dev/null 2>&1; then
        ip=$(avahi-resolve -4 -n "$host" 2>/dev/null | awk '{print $2}')
        if [[ -n $ip ]]; then
            printf '%s' "$ip"
            return 0
        fi
    fi
    # Last resort for the default host only: an mDNS-advertised SSH host that
    # looks like the Pi. An explicitly configured PI_HOST is never replaced.
    if [[ $PI_HOST_EXPLICIT -eq 0 ]] && command -v avahi-browse >/dev/null 2>&1; then
        ip=$(avahi-browse -rtp _ssh._tcp 2>/dev/null |
            awk -F';' '$1 == "=" && tolower($4) ~ /raspberrypi|pizero/ {print $8; exit}')
        if [[ -n $ip ]]; then
            printf '%s' "$ip"
            return 0
        fi
    fi
    printf '%s' "$host"
}

ssh_ok() {
    ssh "${SSH_OPTS[@]}" -o ConnectTimeout=5 "$SSH_TARGET" true 2>/dev/null
}

init_ssh() {
    [[ -n $SSH_TARGET ]] && return 0
    local host
    host=$(resolve_host)
    [[ $host == "$PI_HOST" ]] || note "mDNS unavailable, using $host"
    SSH_TARGET="${PI_USER:+$PI_USER@}$host"
    local err
    if ! err=$(ssh "${SSH_OPTS[@]}" -o ConnectTimeout=10 "$SSH_TARGET" true 2>&1); then
        printf '%s\n' "$err" >&2
        die "cannot SSH to $SSH_TARGET; check PI_USER, run 'ssh-copy-id $SSH_TARGET', and verify the host key for PI_HOST"
    fi
}

# Run a shell command on the Pi as the login user.
remote() {
    init_ssh
    # shellcheck disable=SC2029  # intentional: the command runs on the Pi
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "export XDG_RUNTIME_DIR=/run/user/\$(id -u); $*"
}

# Run a shell command on the Pi as root. The whole command is quoted, so
# "a && b" chains stay inside sudo.
remote_root() {
    init_ssh
    # shellcheck disable=SC2029  # intentional: the command runs on the Pi
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "sudo -n bash -c $(printf '%q' "$*")"
}

reboot_and_wait() {
    local old boot
    old=$(remote "cat /proc/sys/kernel/random/boot_id" | tr -d '\r')
    remote_root "systemctl reboot" >/dev/null 2>&1 || true
    sleep 5
    local i
    for i in $(seq 1 90); do
        if ssh_ok; then
            boot=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r' || true)
            if [[ -n $boot && $boot != "$old" ]]; then
                note "Pi is back ($((i * 5 + 5))s)"
                return 0
            fi
        fi
        sleep 5
    done
    die "Pi did not come back after the reboot"
}

# --- protect (read-only overlay root) ---------------------------------------

protect_state() {
    remote 'if grep -q "overlayroot=tmpfs" /boot/firmware/cmdline.txt 2>/dev/null; then echo on; else echo off; fi'
}

require_writable() {
    [[ $(protect_state) == off ]] ||
        die "root filesystem is overlay-protected; run '$(basename "$0") protect off' first"
}

# --- staging and deployment -------------------------------------------------

stage_tree() {
    command -v python3 >/dev/null 2>&1 || die "python3 is required on this machine"
    [[ -n $GMEDIA_UUID ]] || die "gmediarender UUID not initialised"
    STAGE=$(mktemp -d)
    trap 'rm -rf "$STAGE"' EXIT
    cp -a "$REPO_DIR/pi/." "$STAGE/"
    python3 - "$STAGE" "$SPEAKER_NAME" "$BT_MODE_DEFAULT" "$GMEDIA_UUID" <<'PY'
import os
import sys

root, name, bt_mode, gmedia_uuid = sys.argv[1:5]
plain = name.replace("\\", "\\\\").replace('"', '\\"')
# systemd also expands % specifiers and $ variables in unit files.
systemd = plain.replace("%", "%%").replace("$", "$$")
for dirpath, _dirnames, filenames in os.walk(root):
    for filename in filenames:
        path = os.path.join(dirpath, filename)
        with open(path, "rb") as handle:
            data = handle.read()
        markers = (b"@SPEAKER_NAME", b"@BT_MODE_DEFAULT", b"@GMEDIA_UUID")
        if not any(marker in data for marker in markers):
            continue
        quoted = systemd if filename.endswith((".service", ".timer", ".socket")) else plain
        text = data.decode("utf-8")
        text = text.replace("@SPEAKER_NAME_RAW@", name)
        text = text.replace("@SPEAKER_NAME@", quoted)
        text = text.replace("@BT_MODE_DEFAULT@", bt_mode)
        text = text.replace("@GMEDIA_UUID@", gmedia_uuid)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(text)
PY
    # Never let the checkout's directory modes leak onto /etc, /usr or $HOME.
    chmod -R u=rwX,go=rX "$STAGE"
}

# Stable per-Pi renderer UUID: machine-id is unique and survives redeploys.
gmediarender_uuid() {
    local machine_id
    machine_id=$(remote "cat /etc/machine-id" | tr -d '\r')
    [[ -n $machine_id ]] || die "cannot read /etc/machine-id on the Pi"
    python3 -c 'import sys, uuid; print(uuid.uuid5(uuid.NAMESPACE_DNS, sys.argv[1]))' "$machine_id"
}

deploy_files() {
    say "Deploying pi/ tree to $SSH_TARGET (speaker name: $SPEAKER_NAME)"
    [[ -n $GMEDIA_UUID ]] || GMEDIA_UUID=$(gmediarender_uuid)
    stage_tree

    # Root-owned system files. etc/pizero/bluetooth-mode is user state and is
    # deployed only when absent (deploy_bt_mode).
    tar -C "$STAGE" -cf - --exclude=etc/pizero/bluetooth-mode etc usr |
        ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'sudo -n tar -C / -xf - --no-same-owner --no-overwrite-dir' ||
        die "failed to copy system files"
    remote_root "chown root:root /etc /usr /etc/systemd /etc/systemd/system /etc/systemd/system.conf.d /etc/systemd/journald.conf.d /etc/sysctl.d /etc/bluetooth /usr/local /usr/local/bin"
    remote_root "chmod 0755 /etc /usr /etc/systemd /etc/systemd/system /usr/local /usr/local/bin"
    remote_root "chown -R root:root /etc/pipewire /etc/wireplumber /etc/bluetooth/main.conf /etc/machine-info /etc/shairport-sync.conf /etc/pizero /etc/sysctl.d /etc/systemd/journald.conf.d /etc/systemd/system.conf.d /etc/systemd/system/bluetooth.service.d /etc/systemd/system/avahi-daemon.service.d /etc/systemd/system/pizero-bt-agent.service /etc/systemd/system/pizero-net-watchdog.service /etc/systemd/system/pizero-net-watchdog.timer /usr/local/bin/pizero-bluetooth-radio /usr/local/bin/pizero-bluetooth-mode /usr/local/bin/pizero-bt-agent /usr/local/bin/pizero-bt-pair /usr/local/bin/pizero-bt-pair-close /usr/local/bin/pizero-audio-reconnect /usr/local/bin/pizero-net-watchdog /etc/NetworkManager/dispatcher.d/90-pizero-audio-reconnect"
    remote_root "chmod 0755 /usr/local/bin/pizero-bluetooth-radio /usr/local/bin/pizero-bluetooth-mode /usr/local/bin/pizero-bt-agent /usr/local/bin/pizero-bt-pair /usr/local/bin/pizero-bt-pair-close /usr/local/bin/pizero-audio-reconnect /usr/local/bin/pizero-net-watchdog /etc/NetworkManager/dispatcher.d/90-pizero-audio-reconnect"
    remote_root "chmod 0644 /etc/bluetooth/main.conf /etc/machine-info /etc/shairport-sync.conf /etc/pizero/speaker-name"

    # User-owned units and application config, into the Pi user's $HOME.
    tar -C "$STAGE/home/USER" -cf - . |
        ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'tar -C "$HOME" -xf - --no-overwrite-dir' ||
        die "failed to copy user files"
    deploy_bt_mode
    note "config deployed"
}

deploy_bt_mode() {
    [[ -n $STAGE ]] || stage_tree
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'cat > /tmp/pizero-bluetooth-mode' \
        <"$STAGE/etc/pizero/bluetooth-mode"
    remote_root "install -d -m 0755 -o root -g root /etc/pizero"
    remote_root "test -f /etc/pizero/bluetooth-mode || install -m 0644 -o root -g root /tmp/pizero-bluetooth-mode /etc/pizero/bluetooth-mode"
    remote_root "chmod 0644 /etc/pizero/bluetooth-mode"
    remote_root "rm -f /tmp/pizero-bluetooth-mode"
}

# --- package and system configuration ---------------------------------------

apt_update() {
    say "Updating package lists on the Pi"
    remote_root "DEBIAN_FRONTEND=noninteractive apt-get -y -o Acquire::Retries=3 -o DPkg::Lock::Timeout=900 update"
}

require_supported_os() {
    local os_id os_ver major
    # shellcheck disable=SC2016  # $ID/$VERSION_ID expand on the Pi
    os_id=$(remote '. /etc/os-release && printf "%s" "$ID"' | tr -d '\r')
    # shellcheck disable=SC2016  # $ID/$VERSION_ID expand on the Pi
    os_ver=$(remote '. /etc/os-release && printf "%s" "$VERSION_ID"' | tr -d '\r')
    case $os_id in
        debian | raspbian) ;;
        *) die "unsupported OS on the Pi: ${os_id:-unknown} (need Debian 13 trixie or newer)" ;;
    esac
    major=${os_ver%%.*}
    [[ $major =~ ^[0-9]+$ && $major -ge 13 ]] ||
        die "unsupported OS on the Pi: $os_id $os_ver (need Debian 13 trixie or newer; bookworm is not supported)"
}

apt_install() {
    say "Installing packages on the Pi (this is slow on a Zero W)"
    remote_root "DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=900 install $*"
}

apt_upgrade() {
    say "Updating package lists and upgrading (slow on a Zero W)"
    remote_root "DEBIAN_FRONTEND=noninteractive apt-get -y -o Acquire::Retries=3 -o DPkg::Lock::Timeout=900 update"
    remote_root "DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold -o Acquire::Retries=3 -o DPkg::Lock::Timeout=900 full-upgrade"
}

apt_reinstall() {
    say "Reinstalling speaker packages"
    remote_root "DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=900 install --reinstall $*"
}

configure_boot() {
    say "Configuring console boot and lingering user session"
    remote_root "systemctl set-default multi-user.target >/dev/null"
    remote_root "loginctl enable-linger $(remote 'id -un' | tr -d '\r')"
}

configure_wifi() {
    local uuid
    uuid=$(remote "nmcli -t -f NAME,UUID,TYPE connection show 2>/dev/null" |
        awk -F: '$3 == "802-11-wireless" {print $2; exit}' | tr -d '\r')
    if [[ -z $uuid ]]; then
        note "no Wi-Fi profile found, skipping autoconnect policy"
        return 0
    fi
    say "Wi-Fi: infinite autoconnect retries for profile $uuid"
    # NetworkManager on a Zero sometimes reports a timeout even though the
    # update was applied, so verify the stored values instead of the exit code.
    remote_root "nmcli --wait 30 connection modify $uuid connection.autoconnect yes connection.autoconnect-retries 0" || true
    local current
    current=$(remote "nmcli -g connection.autoconnect,connection.autoconnect-retries connection show $uuid" | tr -d '\r' | paste -sd:)
    if [[ $current == "yes:0" ]]; then
        note "autoconnect is unlimited"
    else
        note "warning: could not confirm autoconnect settings ($current)"
    fi
}

configure_system() {
    say "Applying watchdog, panic, journal and package-timer settings"
    remote_root "sysctl --system >/dev/null"
    remote_root "systemctl daemon-reexec"
    remote_root "systemctl enable --now systemd-timesyncd.service >/dev/null 2>&1 || true"
    remote_root "systemctl enable --now rtkit-daemon.service >/dev/null 2>&1 || true"
    remote_root "systemctl disable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true"
    remote_root "systemctl mask apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true"
    remote_root "systemctl disable --now unattended-upgrades.service >/dev/null 2>&1 || true"
    remote_root "systemctl mask unattended-upgrades.service >/dev/null 2>&1 || true"
    remote_root "systemctl restart systemd-journald"
}

install_spotify_binary() {
    local force=${1:-} arch bin
    [[ -f $SPOTIFY_UNIT ]] || die "missing Spotify unit: ${SPOTIFY_UNIT#"$REPO_DIR"/}"
    [[ -x $SPOTIFY_BUILD ]] || die "missing $SPOTIFY_BUILD"

    arch=$(remote "dpkg --print-architecture" | tr -d '\r')
    case $arch in
        armhf | arm64) ;;
        *) die "unsupported Pi architecture: $arch" ;;
    esac
    bin="$REPO_DIR/build/spotify-connect-$arch"

    if [[ ! -x $bin || -n $force ]]; then
        if [[ -n $force ]]; then
            "$SPOTIFY_BUILD" --force "$arch"
        else
            "$SPOTIFY_BUILD" "$arch"
        fi
    fi
    [[ -x $bin ]] || die "Spotify binary was not produced at $bin"

    say "Installing Spotify Connect binary ($arch)"
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'cat > /tmp/spotify-connect' <"$bin"
    remote_root "install -m 0755 -o root -g root /tmp/spotify-connect /usr/local/bin/spotify-connect && rm -f /tmp/spotify-connect"
}

retire_legacy_units() {
    # Earlier revisions used bt-agent + a separate trust daemon. bt-agent can
    # linger in "deactivating", so kill it instead of waiting for the timeout.
    remote_root "systemctl disable bt-agent.service pizero-bt-trust.service >/dev/null 2>&1 || true"
    remote_root "systemctl kill -s SIGKILL bt-agent.service >/dev/null 2>&1 || true"
    remote_root "systemctl reset-failed bt-agent.service pizero-bt-trust.service >/dev/null 2>&1 || true"
    remote_root "rm -f /etc/systemd/system/bt-agent.service /etc/systemd/system/pizero-bt-trust.service /usr/local/bin/pizero-bt-trust"
    # The A2DP input is routed by PipeWire itself; drop the old loopback unit.
    remote "systemctl --user disable --now pizero-bt-loopback.service >/dev/null 2>&1 || true"
    remote "rm -f \"\$HOME/.config/systemd/user/pizero-bt-loopback.service\""
    remote_root "rm -f /usr/local/bin/pizero-bt-loopback"
}

mask_system_daemons() {
    say "Disabling distro system units that would grab the audio device"
    remote_root "systemctl disable --now shairport-sync.service gmediarender.service >/dev/null 2>&1 || true"
    remote_root "systemctl mask shairport-sync.service gmediarender.service >/dev/null 2>&1 || true"
}

enable_units() {
    say "Enabling services"
    remote "systemctl --user enable pipewire.socket pipewire.service pipewire-pulse.socket pipewire-pulse.service wireplumber.service >/dev/null 2>&1 || true"
    remote_root "systemctl enable avahi-daemon.service pizero-bluetooth-radio.service pizero-bt-agent.service pizero-net-watchdog.timer >/dev/null"
    remote "systemctl --user enable ${USER_SERVICES[*]} >/dev/null"
}

reload_units() {
    remote_root "systemctl daemon-reload"
    remote "systemctl --user daemon-reload"
}

restart_services() {
    say "Restarting services"
    # Bluetooth first: applies main.conf, re-powers the adapter and the mode.
    remote_root "systemctl restart bluetooth.service"
    remote_root "systemctl restart pizero-bluetooth-radio.service pizero-bt-agent.service pizero-net-watchdog.timer || true"
    # Take the clients down first, then rebuild the graph in dependency order:
    # WirePlumber must not start while PipeWire is still tearing objects down.
    remote "systemctl --user stop ${APP_SERVICES[*]}" || true
    remote "systemctl --user stop wireplumber.service" || true
    remote "systemctl --user restart pipewire.socket pipewire.service" || true
    remote "systemctl --user restart pipewire-pulse.socket pipewire-pulse.service" || true
    sleep 2
    remote "systemctl --user restart wireplumber.service" || true
    sleep 3
    remote "systemctl --user restart ${APP_SERVICES[*]}" || true
    note "services restarted"
}

verify_active() {
    say "Verifying services"
    local failed=0 name state
    for name in "${USER_SERVICES[@]}"; do
        state=$(remote "systemctl --user is-active $name.service 2>/dev/null || true" | tr -d '\r')
        [[ $state == active ]] || { note "user/$name: $state"; failed=1; }
    done
    for name in "${SYSTEM_SERVICES[@]}"; do
        state=$(remote_root "systemctl is-active $name.service 2>/dev/null || true" | tr -d '\r')
        [[ $state == active ]] || { note "system/$name: $state"; failed=1; }
    done
    for name in "${SYSTEM_TIMERS[@]}"; do
        state=$(remote_root "systemctl is-active $name 2>/dev/null || true" | tr -d '\r')
        [[ $state == active ]] || { note "timer/$name: $state"; failed=1; }
    done
    ((failed == 0)) || die "some services are not active (see: $(basename "$0") status)"
}

# --- commands ---------------------------------------------------------------

cmd_setup() {
    init_ssh
    require_writable
    require_supported_os
    configure_boot
    apt_update
    apt_install "${PKGS[@]}"
    configure_wifi
    install_spotify_binary
    deploy_files
    configure_system
    retire_legacy_units
    mask_system_daemons
    reload_units
    enable_units
    restart_services
    verify_active
    say "Setup complete - the Pi advertises as '$SPEAKER_NAME'"
}

cmd_update() {
    init_ssh
    require_writable
    require_supported_os
    apt_upgrade
    install_spotify_binary force
    deploy_files
    configure_system
    retire_legacy_units
    mask_system_daemons
    reload_units
    enable_units
    restart_services
    verify_active
    say "Update complete"
}

cmd_reinstall() {
    init_ssh
    require_writable
    require_supported_os
    apt_update
    apt_reinstall "${PKGS[@]}"
    install_spotify_binary force
    deploy_files
    configure_system
    retire_legacy_units
    mask_system_daemons
    reload_units
    enable_units
    restart_services
    verify_active
    say "Reinstall complete"
}

cmd_restart() {
    init_ssh
    restart_services
    verify_active
}

cmd_status() {
    init_ssh
    remote 'bash -s' <<'STATUS'
export XDG_RUNTIME_DIR=/run/user/$(id -u)
svc() {
    local unit=$1 scope=${2:-} state name
    name=$unit
    [[ $name == *.* ]] || name="$name.service"
    if [[ -n $scope ]]; then
        state=$(systemctl --user is-active "$name" 2>/dev/null || true)
    else
        state=$(systemctl is-active "$name" 2>/dev/null || true)
    fi
    printf '  %-18s %s\n' "$unit" "${state:-unknown}"
}
pretty=$(sed -n 's/^PRETTY_HOSTNAME="\(.*\)"/\1/p' /etc/machine-info 2>/dev/null)
printf 'Speaker "%s" on %s\n' "${pretty:-unknown}" "$(hostname)"
printf '  %-18s %s\n' "overlay root" "$(grep -q 'overlayroot=tmpfs' /boot/firmware/cmdline.txt 2>/dev/null && echo on || echo off)"
printf 'Services (user):\n'
for s in pipewire wireplumber pipewire-pulse shairport-sync gmediarender spotify-connect; do
    svc "$s" --user
done
printf 'Services (system):\n'
for s in bluetooth pizero-bt-agent avahi-daemon; do
    svc "$s" ""
done
svc "pizero-net-watchdog.timer" ""
printf 'Bluetooth:\n'
bt=$(bluetoothctl show 2>/dev/null || true)
for k in Name Alias Powered Discoverable Pairable; do
    v=$(sed -n "s/^[[:space:]]*$k: //p" <<<"$bt" | head -1)
    printf '  %-14s %s\n' "$k" "${v:-?}"
done
printf '  %-14s %s\n' "mode" "$(cat /etc/pizero/bluetooth-mode 2>/dev/null || echo locked)"
printf '  %-14s %s\n' "paired" "$(bluetoothctl devices Paired 2>/dev/null | wc -l) device(s)"
bluetoothctl devices Paired 2>/dev/null | while read -r _ mac name; do
    printf '    %s %s\n' "$mac" "$name"
done
printf 'Audio:\n'
printf '  %-14s %s\n' "default sink" "$(pactl get-default-sink 2>/dev/null || echo '?')"
printf '  %-14s %s\n' "USB DAC" "$(pactl list short sinks 2>/dev/null | grep -qiE 'usb-' && echo present || echo absent)"
printf '  %-14s %s\n' "sinks" "$(pactl list short sinks 2>/dev/null | awk '{print $2}' | paste -sd, -)"
printf 'Network:\n'
printf '  %-14s %s\n' "wifi" "$(nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1; exit}')"
printf '  %-14s %s\n' "gateway" "$(ip route show default 2>/dev/null | awk '/^default/{print $3; exit}')"
printf 'System:\n'
printf '  %-14s %s\n' "loadavg" "$(cut -d' ' -f1-3 /proc/loadavg)"
printf '  %-14s %s\n' "memory" "$(free -m | awk '/^Mem:/ {printf "%d MB used / %d MB total", $3, $2}')"
printf '  %-14s %s\n' "uptime" "$(uptime -p)"
STATUS
}

cmd_logs() {
    init_ssh
    local service=${1:-}
    if [[ -z $service ]]; then
        remote "journalctl --user -n 40 --no-pager -u shairport-sync -u gmediarender -u spotify-connect"
        remote_root "journalctl -n 40 --no-pager -u bluetooth -u pizero-bt-agent -u pizero-net-watchdog -u avahi-daemon"
        return
    fi
    case " ${USER_SERVICES[*]} " in
        *" $service "*) remote "journalctl --user -n 120 --no-pager -u $service" ;;
        *) remote_root "journalctl -n 120 --no-pager -u $service" ;;
    esac
}

cmd_bt_pair() {
    init_ssh
    require_writable
    remote_root "pizero-bt-pair ${1:-120}"
}

cmd_bt_mode() {
    init_ssh
    require_writable
    local mode=${1:-}
    case $mode in
        open | locked) ;;
        *) die "usage: $(basename "$0") bt-mode open|locked" ;;
    esac
    remote_root "install -d -m 0755 -o root -g root /etc/pizero"
    remote_root "printf '%s\n' '$mode' > /etc/pizero/bluetooth-mode && chmod 0644 /etc/pizero/bluetooth-mode"
    remote_root "rm -f /run/pizero/bt-pair-until; systemctl stop pizero-bt-pair-timeout.service pizero-bt-pair-timeout.timer >/dev/null 2>&1 || true"
    remote_root "/usr/local/bin/pizero-bluetooth-mode apply"
}

cmd_bt_devices() {
    init_ssh
    remote 'bash -s' <<'DEVS'
export XDG_RUNTIME_DIR=/run/user/$(id -u)
printf 'mode: %s\n' "$(cat /etc/pizero/bluetooth-mode 2>/dev/null || echo locked)"
found=0
for mac in $(bluetoothctl devices Paired 2>/dev/null | awk '{print $2}'); do
    found=1
    info=$(bluetoothctl info "$mac" 2>/dev/null)
    field() { sed -n "s/^[[:space:]]*$1: //p" <<<"$info" | head -1; }
    printf '  %-17s %-24.24s trusted=%-3s connected=%s\n' \
        "$mac" "$(field Name)" "$(field Trusted)" "$(field Connected)"
done
[ "$found" = 1 ] || echo "  (none)"
DEVS
}

cmd_bt_forget() {
    init_ssh
    require_writable
    local mac=${1:-}
    [[ $mac =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]] ||
        die "usage: $(basename "$0") bt-forget <MAC>"
    remote_root "bluetoothctl --timeout 10 remove $mac"
    note "forgot $mac"
}

cmd_protect() {
    init_ssh
    local action=${1:-status}
    case $action in
        status)
            note "overlay root: $(protect_state)"
            ;;
        on)
            if [[ $(protect_state) == on ]]; then
                note "overlay root already on"
                return 0
            fi
            say "Enabling the read-only overlay root (reboots the Pi)"
            remote_root "raspi-config nonint enable_overlayfs" ||
                die "could not enable the overlay root"
            reboot_and_wait
            [[ $(protect_state) == on ]] || die "overlay root is not active after the reboot"
            say "Overlay root enabled; '/' is now read-only across reboots"
            ;;
        off)
            if [[ $(protect_state) == off ]]; then
                note "overlay root already off"
                return 0
            fi
            say "Disabling the read-only overlay root (reboots the Pi)"
            remote_root "raspi-config nonint disable_overlayfs" ||
                die "could not disable the overlay root"
            reboot_and_wait
            [[ $(protect_state) == off ]] || die "overlay root is still active after the reboot"
            say "Overlay root disabled"
            ;;
        *)
            die "usage: $(basename "$0") protect on|off|status"
            ;;
    esac
}

main() {
    [[ $# -ge 1 ]] || { usage; exit 2; }
    case $1 in
        setup) cmd_setup ;;
        update) cmd_update ;;
        reinstall) cmd_reinstall ;;
        status) cmd_status ;;
        restart) cmd_restart ;;
        logs) shift; cmd_logs "${1:-}" ;;
        bt-pair) shift; cmd_bt_pair "${1:-}" ;;
        bt-mode) shift; cmd_bt_mode "${1:-}" ;;
        bt-devices) cmd_bt_devices ;;
        bt-forget) shift; cmd_bt_forget "${1:-}" ;;
        protect) shift; cmd_protect "${1:-status}" ;;
        -h | --help | help) usage ;;
        *) usage >&2; exit 2 ;;
    esac
}

main "$@"
