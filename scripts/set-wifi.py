#!/usr/bin/env python3
"""Add or replace a Wi-Fi network on a Raspberry Pi OS SD card from another Linux PC.

Use this when the Pi doesn't join your Wi-Fi (wrong password, changed network name).
Put the Pi's SD card in a card reader, mount it (most desktops do this automatically,
or: udisksctl mount -b /dev/sdX2), then run:

    sudo python3 scripts/set-wifi.py --ssid "My Network"

The Wi-Fi password is asked for (hidden, twice) and stored hashed; it is never printed.
Options:
    --ssid NAME       Wi-Fi network name (asked for if omitted)
    --rootfs PATH     mount point of the card's "rootfs" partition (auto-detected)
    --hidden          the network does not broadcast its name
    --replace-all     remove all other Wi-Fi networks stored on the card
"""
import argparse, getpass, hashlib, os, re, subprocess, sys, uuid


def is_running_system(path):
    """True if path is (on the same file system as) this PC's own root."""
    return os.stat(path).st_dev == os.stat("/").st_dev


def find_rootfs():
    """Mount point of a mounted partition labelled 'rootfs' that holds Raspberry Pi OS."""
    out = subprocess.run(["lsblk", "-rno", "LABEL,MOUNTPOINT"], capture_output=True, text=True).stdout
    hits = [m.replace("\\x20", " ") for label, _, m in (line.partition(" ") for line in out.splitlines())
            if label == "rootfs" and m]
    hits = [m for m in hits
            if os.path.isdir(os.path.join(m, "etc/NetworkManager")) and not is_running_system(m)]
    if len(hits) != 1:
        sys.exit("could not find exactly one mounted Pi 'rootfs' partition; pass --rootfs PATH "
                 f"(found: {hits or 'none'})")
    return hits[0]


def keyfile_ssid(ssid):
    """NetworkManager keyfile value for an SSID: plain text if safe, else a byte list."""
    if re.fullmatch(r"[!-~](?:[ -~]*[!-~])?", ssid) and ";" not in ssid and "\\" not in ssid:
        return ssid
    return "".join(f"{b};" for b in ssid.encode())


def mount_options(path):
    return subprocess.run(["findmnt", "-no", "OPTIONS", "--target", path],
                          capture_output=True, text=True, check=True).stdout.strip().split(",")


p = argparse.ArgumentParser(description="Set the Wi-Fi network on a Raspberry Pi OS SD card.")
p.add_argument("--ssid")
p.add_argument("--rootfs")
p.add_argument("--hidden", action="store_true")
p.add_argument("--replace-all", action="store_true")
args = p.parse_args()

if os.geteuid() != 0:
    sys.exit("run with sudo")
rootfs = args.rootfs or find_rootfs()
if is_running_system(rootfs):
    sys.exit(f"{rootfs} is this computer's own system, not a Pi SD card - nothing changed")
nm_dir = os.path.join(rootfs, "etc/NetworkManager/system-connections")
if not os.path.isdir(nm_dir):
    sys.exit(f"{nm_dir} missing - is this a Raspberry Pi OS (Bookworm or newer) card?")

ssid = args.ssid or input("Wi-Fi network name: ")
if not 1 <= len(ssid.encode()) <= 32:
    sys.exit("Wi-Fi names are 1-32 bytes - nothing changed")
pw = getpass.getpass(f"Wi-Fi password for {ssid}: ")
if getpass.getpass("Repeat password: ") != pw:
    sys.exit("passwords differ - nothing changed")
if not 8 <= len(pw) <= 63:
    sys.exit(f"WPA passwords are 8-63 characters, got {len(pw)} - nothing changed")
psk_hex = hashlib.pbkdf2_hmac("sha1", pw.encode(), ssid.encode(), 4096, 32).hex()

safe_name = re.sub(r"[^A-Za-z0-9._-]+", "_", ssid).strip("_") or "wifi"
target = os.path.join(nm_dir, f"{safe_name}.nmconnection")
was_ro = "ro" in mount_options(rootfs)

if was_ro:
    subprocess.run(["mount", "-o", "remount,rw", rootfs], check=True)
try:
    for name in os.listdir(nm_dir):
        path = os.path.join(nm_dir, name)
        if path == target:
            continue
        with open(path, errors="replace") as f:
            content = f.read()
        same_ssid = re.search(rf"^ssid={re.escape(keyfile_ssid(ssid))}$", content, re.M)
        if args.replace_all and "type=wifi" in content or same_ssid:
            os.remove(path)
            print("== removed", name)
    profile = f"""[connection]
id={safe_name}
uuid={uuid.uuid4()}
type=wifi
autoconnect=true
autoconnect-retries=0

[wifi]
mode=infrastructure
ssid={keyfile_ssid(ssid)}
hidden={'true' if args.hidden else 'false'}
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
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(profile)
    os.chown(target, 0, 0)
    os.chmod(target, 0o600)
    print("== wrote", target.removeprefix(rootfs))
finally:
    os.sync()
    if was_ro:
        subprocess.run(["mount", "-o", "remount,ro", rootfs], check=True)
print("== done; unmount the card (e.g. udisksctl unmount -b /dev/sdX1 and /dev/sdX2) and put it back in the Pi")
