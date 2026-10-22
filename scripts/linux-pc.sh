#!/usr/bin/env bash
# Make AirPlay speakers on the LAN (e.g. "PiZERO Speakers") show up as normal audio
# outputs on this Linux PC (PipeWire). Pick them in the sound settings like any device.
#
# Usage: linux-pc.sh enable [LATENCY_MS] | disable | status
#   LATENCY_MS  AirPlay buffer in milliseconds (default 500). Lower = less delay,
#               higher = more robust against Wi-Fi hiccups (PipeWire's default is 1000).
#
# Discovery runs as a small separate PipeWire client (user service pizero-airplay),
# so enabling/disabling never restarts PipeWire or disconnects running apps.
# A timer (pizero-airplay-heal) re-adds speakers that dropped off, e.g. after the Pi
# was offline; it calls this script, so keep the script where it was when enabled.
set -euo pipefail

CFG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
CONF="$CFG_HOME/pipewire/pizero-airplay.conf"
UNIT_DIR="$CFG_HOME/systemd/user"
UNIT="pizero-airplay.service"
HEAL_UNIT="pizero-airplay-heal"
SELF="$(realpath "${BASH_SOURCE[0]}")"
LEGACY_DROPIN="$CFG_HOME/pipewire/pipewire.conf.d/50-airplay-discover.conf"

write_conf() {
  local latency="$1"
  mkdir -p "$(dirname "$CONF")" "$UNIT_DIR"
  cat >"$CONF" <<EOF
# Written by linux-pc.sh: discover AirPlay (RAOP) speakers and add them as outputs.
# AirPlay buffer ${latency} ms. IPv4 only, so each speaker gets one output with a
# stable name and the desktop remembers it as the default output.
context.properties = {
    log.level = 2
}
context.spa-libs = {
    audio.convert.* = audioconvert/libspa-audioconvert
    support.*       = support/libspa-support
}
context.modules = [
    { name = libpipewire-module-rt args = { } flags = [ ifexists nofail ] }
    { name = libpipewire-module-protocol-native }
    { name = libpipewire-module-client-node }
    { name = libpipewire-module-adapter }
    { name = libpipewire-module-raop-discover
      args = {
        stream.rules = [
          { matches = [ { raop.ip = "~^[0-9.]+\$" } ]
            actions = { create-stream = { raop.latency.ms = ${latency} } } }
        ]
      }
    }
]
EOF
  cat >"$UNIT_DIR/$UNIT" <<EOF
[Unit]
Description=AirPlay speakers as PipeWire outputs (linux-pc.sh)
After=pipewire.service
BindsTo=pipewire.service

[Service]
ExecStart=/usr/bin/pipewire -c $CONF
Restart=always
RestartSec=5

[Install]
WantedBy=pipewire.service
EOF
  # Self-heal: PipeWire's discovery does not retry a speaker whose lookup failed
  # (e.g. the Pi was offline for a moment), so check every minute.
  cat >"$UNIT_DIR/$HEAL_UNIT.service" <<EOF
[Unit]
Description=Re-add AirPlay speakers that dropped off (linux-pc.sh)

[Service]
Type=oneshot
ExecStart=$SELF heal
EOF
  cat >"$UNIT_DIR/$HEAL_UNIT.timer" <<EOF
[Unit]
Description=Check AirPlay speaker outputs every minute (linux-pc.sh)

[Timer]
OnActiveSec=1min
OnUnitActiveSec=1min

[Install]
WantedBy=timers.target
EOF
}

# Is any stream currently routed to an AirPlay output?
airplay_in_use() {
  awk 'NR == FNR { if ($2 ~ /^raop_sink/) raop[$1] = 1; next } ($2 in raop) { found = 1; exit } END { exit !found }' \
    <(pactl list sinks short) <(pactl list sink-inputs short)
}

# Restart discovery if a Shairport Sync speaker is announced on the LAN but has no
# output here. Never interrupts playback (checked again right before restarting) and
# restarts at most once per 5 minutes, so a speaker that never attaches can't cause a loop.
heal() {
  command -v avahi-browse >/dev/null || exit 0
  systemctl --user is-active --quiet "$UNIT" || exit 0
  pactl info >/dev/null 2>&1 || exit 0   # sound server unreachable: nothing to judge
  airplay_in_use && exit 0
  local stamp="${XDG_RUNTIME_DIR:-/tmp}/pizero-airplay-heal.last" sinks ip missing=""
  if [ -f "$stamp" ] && (( $(date +%s) - $(stat -c %Y "$stamp") < 300 )); then exit 0; fi
  sinks="$(pactl list sinks short)"
  while IFS=';' read -r _ _ proto _ _ _ _ ip _ txt; do
    [ "$proto" = IPv4 ] && [[ "$txt" == *'"am=ShairportSync"'* ]] || continue
    # Output names look like raop_sink.<host>.<ip>.<port>
    awk -v ip="$ip" '$2 ~ /^raop_sink/ && index($2, "." ip ".") {found = 1} END {exit !found}' <<<"$sinks" \
      || missing+=" $ip"
  done < <(timeout 10 avahi-browse -rtpk _raop._tcp 2>/dev/null | grep '^=')
  [ -n "$missing" ] || exit 0
  airplay_in_use && exit 0
  touch "$stamp"
  echo "AirPlay speaker(s) without output:$missing; restarting $UNIT"
  systemctl --user restart "$UNIT"
}

case "${1:-}" in
  enable)
    latency="${2:-500}"
    [[ "$latency" =~ ^[0-9]+$ ]] && (( latency >= 100 )) || { echo "LATENCY_MS must be a number >= 100" >&2; exit 2; }
    write_conf "$latency"
    if [ -f "$LEGACY_DROPIN" ]; then
      rm -f "$LEGACY_DROPIN"
      echo "removed old $LEGACY_DROPIN (its outputs disappear at next login)"
    fi
    systemctl --user daemon-reload
    systemctl --user enable "$UNIT" >/dev/null
    systemctl --user enable --now "$HEAL_UNIT.timer" >/dev/null
    systemctl --user restart "$UNIT"
    echo "AirPlay outputs enabled (buffer ${latency} ms); they appear within a few seconds"
    ;;
  disable)
    systemctl --user disable --now "$HEAL_UNIT.timer" "$UNIT" 2>/dev/null || true
    rm -f "$CONF" "$UNIT_DIR/$UNIT" "$UNIT_DIR/$HEAL_UNIT.service" "$UNIT_DIR/$HEAL_UNIT.timer" "$LEGACY_DROPIN"
    systemctl --user daemon-reload
    echo "AirPlay outputs disabled"
    ;;
  status)
    printf 'service: %s, self-heal timer: %s\n' \
      "$(systemctl --user is-active "$UNIT" 2>/dev/null || true)" \
      "$(systemctl --user is-active "$HEAL_UNIT.timer" 2>/dev/null || true)"
    [ -f "$CONF" ] && grep -o 'raop.latency.ms = [0-9]*' "$CONF" | sed 's/^/config: /'
    echo "AirPlay outputs:"
    pactl list sinks short | awk '$2 ~ /^raop_sink/ {print "  " $2}' | grep . || echo "  (none found yet; discovery takes a few seconds)"
    ;;
  heal)
    heal
    ;;
  *)
    echo "usage: $(basename "$0") enable [LATENCY_MS] | disable | status" >&2
    exit 2
    ;;
esac
