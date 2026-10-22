#!/usr/bin/env python3
"""Configure the Pi's SD card (mounted at /media/ronald/rootfs) for Wi-Fi MagentaWLAN-L4ZT.

Run as: sudo python3 ~/Documents/PiZERO/scripts/set-wifi.py
Prompts for the Wi-Fi password (hidden); never prints it.
"""
import configparser, getpass, hashlib, os, subprocess, sys, uuid

SSID = "MagentaWLAN-L4ZT"
ROOTFS = "/media/ronald/rootfs"
NM_DIR = f"{ROOTFS}/etc/NetworkManager/system-connections"
TARGET = f"{NM_DIR}/magenta-wlan.nmconnection"
OLD_BACKUP = f"{ROOTFS}/root/preconfigured.nmconnection.bak"

if os.geteuid() != 0:
    sys.exit("run with sudo")
if not os.path.isdir(NM_DIR):
    sys.exit(f"{NM_DIR} missing - is the SD card mounted?")

pw = getpass.getpass(f"Wi-Fi password for {SSID}: ")
if getpass.getpass("Repeat password: ") != pw:
    sys.exit("passwords differ - nothing changed")
if not 8 <= len(pw) <= 63:
    sys.exit(f"WPA passwords are 8-63 characters, got {len(pw)} - nothing changed")
psk_hex = hashlib.pbkdf2_hmac("sha1", pw.encode(), SSID.encode(), 4096, 32).hex()

# Diagnostic: does it match what the Pi had stored before?
if os.path.exists(OLD_BACKUP):
    cp = configparser.ConfigParser(interpolation=None)
    cp.read(OLD_BACKUP)
    old = cp.get("wifi-security", "psk", fallback="")
    if cp.get("wifi", "ssid", fallback="") == SSID and old:
        same = old == pw or old.lower() == psk_hex
        print("== password matches the one previously on the card:", "YES" if same else "NO")

subprocess.run(["mount", "-o", "remount,rw", ROOTFS], check=True)
try:
    for name in os.listdir(NM_DIR):
        os.remove(os.path.join(NM_DIR, name))
        print("== removed", name)
    profile = f"""[connection]
id={SSID}
uuid={uuid.uuid4()}
type=wifi
autoconnect=true

[wifi]
mode=infrastructure
ssid={SSID}
band=bg
powersave=2

[wifi-security]
key-mgmt=wpa-psk
psk={psk_hex}

[ipv4]
method=auto

[ipv6]
method=auto
addr-gen-mode=default
"""
    fd = os.open(TARGET, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(profile)
    os.chown(TARGET, 0, 0)
    print("== wrote", TARGET.removeprefix(ROOTFS))
finally:
    os.sync()
    subprocess.run(["mount", "-o", "remount,ro", ROOTFS], check=True)
print("== done; eject with: udisksctl unmount -b /dev/sda1 && udisksctl unmount -b /dev/sda2")
