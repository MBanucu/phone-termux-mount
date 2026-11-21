# phone-termux-mount

NixOS module that mounts a Termux home directory from an adb-connected Android phone
over sshfs, with one systemd unit that keeps the `adb forward` and Termux's `sshd`
alive alongside the mount.

```console
$ ls ~/phone-termux
android-sdk  go  projects      # Termux' own home, as a normal directory
```

No root on the phone, no debuggable Termux, no Samba: it is plain SSH over the adb
forward you would otherwise set up by hand.

## What it sets up

| Piece | Purpose |
|---|---|
| `phone-termux-mount.service` | runs as **your user**, sshfs mounting `/data/data/com.termux/files/home` in the foreground. Its `ExecStartPre` differs by transport: `adb` waits for the phone, creates `adb forward tcp:8022 tcp:8022`, then checks sshd; `direct` only checks sshd. In both cases the phone is asked to start sshd through the [`termux-adb-bridge`](https://github.com/MBanucu/termux-adb-bridge) app when it does not answer |
| `phone-termux-mount-watchdog.timer` | every 2 min, probes sshd; when a mount that claims to be `active` no longer answers, restarts the mount unit so it resyncs instead of sitting there dead |

The mount is started at boot and restarted every 30 s while the phone is unreachable, so
replugging or rebooting the phone heals on its own. Because sshfs runs as your user,
files come back owned by you (`idmap=user`) with no `uid=`/`gid=` guesswork — which
matters, since NixOS assigns normal-user ids at activation and they are `null` while the
configuration is evaluated.

## Requirements

On the phone, once:

1. Termux installed, with `sshd` available: `pkg install openssh`.
2. An SSH key from this machine in `~/.ssh/authorized_keys` (chmod 600).
   If you use the mount only, a key without a passphrase is what you want, since the
   mount happens in the background.
3. Optional but recommended: [`com.termux.adbbridge`](https://github.com/MBanucu/termux-adb-bridge)
   installed and granted, so `startSshd` can restart `sshd` without you touching the phone.
4. For `transport = "direct"` (no adb at all), `sshd` must start on its own after a
   reboot — see [sshd at boot](#sshd-at-boot).

On the NixOS machine: `adb devices` must show the phone as `device` (that authorizes
USB access; adb's udev rules are enabled by this module).

## Install

`flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    phone-termux-mount = {
      url = "github:MBanucu/phone-termux-mount";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { nixpkgs, phone-termux-mount, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        phone-termux-mount.nixosModules.default
        {
          services.phoneTermuxMount = {
            enable = true;
            user = "michi";
            remoteUser = "u0_a514";      # `whoami` inside Termux
          };
        }
      ];
    };
  };
}
```

Then `sudo nixos-rebuild switch --flake .#myhost`.

Without flakes, the module is a single self-contained file:

```nix
imports = [ "${builtins.fetchTarball "https://github.com/MBanucu/phone-termux-mount/archive/main.tar.gz"}/module.nix" ];
```

## Options

| Option | Default | Meaning |
|---|---|---|
| `enable` | `false` | turn the module on |
| `transport` | `"adb"` | `adb` for the forward over adb, `direct` for ssh straight to the phone's sshd |
| `user` | — | local account owning the mountpoint, running the adb forward |
| `remoteUser` | — | Termux's Linux user (`whoami` in Termux, e.g. `u0_a514`) |
| `sshHost` | `"127.0.0.1"` | host of the adb forward |
| `port` | `8022` | sshd and forward port |
| `remotePath` | `/data/data/com.termux/files/home` | directory to mount |
| `mountpoint` | `/home/<user>/phone-termux` | where it appears locally |
| `identityFile` | `/home/<user>/.ssh/id_ed25519_phone` | key authorized in Termux |
| `startSshd` | `true` | ask the bridge app to start sshd when it does not answer |
| `extraOptions` | `[]` | extra sshfs options, e.g. `[ "cache=yes" ]` |
| `watchdog.enable` | `true` | restart the mount when sshd stops answering |
| `watchdog.interval` | `"2min"` | how often the watchdog probes sshd |
| `wifi.enable` | `false` | use adb over Wi-Fi instead of the cable, and prefer it when available |
| `wifi.host` | — | the phone's address on the network (required when `wifi.enable`) |
| `wifi.port` | `5555` | port adbd listens on in TCP mode |
| `wifi.bootstrapUsb` | `true` | if nothing listens yet and the phone is on USB, run `adb tcpip` once |

## Using it

```console
$ ls ~/phone-termux                       # the mounted home
$ systemctl status phone-termux-mount     # mount + forward/sshd state
$ journalctl -u phone-termux-mount -e     # its log
$ systemctl restart phone-termux-mount    # re-run forward + sshd + mount
```

## Cable-free mode

```nix
services.phoneTermuxMount = {
  enable = true;
  user = "michi";
  remoteUser = "u0_a514";
  wifi = {
    enable = true;
    host = "192.168.77.232";   # the phone's wlan0 address
  };
};
```

Before mounting, the unit runs `phone-connect`, which makes sure an adb transport
exists over the network, then uses `host:5555` in preference to USB:

1. already connected over TCP → nothing to do
2. `adb connect host:5555`
3. otherwise try the Wi-Fi neighbours from the ARP table (handy when the phone's
   address is DHCP and you do not want to pin it)
4. if nothing listens but the phone is on USB, `adb tcpip 5555` once, then retry

The catch: classic TCP mode does **not** survive a reboot, because adbd comes back
USB-only. After a power cycle you need one USB connection (or Android's Wireless
debugging toggle, whose port is random and handled by mDNS instead) before the
module can go cable-free again.

Run the helper on its own with:

```console
$ nix run github:MBanucu/phone-termux-mount#phone-connect
$ PHONE_HOST=192.168.77.232 nix run .#phone-connect
```

## sshd at boot

`transport = "direct"` talks to the phone's own `sshd`, so nothing needs keeping alive —
but `sshd` has to be running after a reboot, and Termux only starts it when someone asks.
The supported way is the official [Termux:Boot](https://github.com/termux/termux-boot)
add-on plus a script in `~/.termux/boot/`.

1. Install Termux:Boot **from the same source as Termux**. It shares Termux's UID
   (`sharedUser=com.termux`) and runs the scripts itself, so a different signing key means
   it is a different app and cannot see `~/.termux/boot` at all:

   | Termux came from | Install from |
   |---|---|
   | F-Droid (`installerPackageName=org.fdroid.fdroid`) | <https://f-droid.org/packages/com.termux.boot/> |
   | GitHub releases | <https://github.com/termux/termux-boot/releases> |

   Open the add-on once after installing. Some ROMs (Blackview, Xiaomi, ColorOS) block
   boot receivers of apps that were never launched; one manual start lifts that. Also make
   sure Termux is exempt from battery optimisation, or the boot job never runs.

2. Create the script. Termux:Boot executes everything in `~/.termux/boot/` (mode 700):

   ```sh
   mkdir -p ~/.termux/boot
   cat > ~/.termux/boot/start-sshd <<'EOF'
   #!/data/data/com.termux/files/usr/bin/sh
   # Run by Termux:Boot at boot: keep sshd up so the sshfs mount reconnects.
   /data/data/com.termux/files/usr/bin/sshd
   EOF
   chmod 700 ~/.termux/boot/start-sshd
   ```

3. Test it without rebooting — the script is what matters, and it can be run directly:

   ```console
   $ pkill sshd                       # the mount drops
   $ sh ~/.termux/boot/start-sshd     # or let Termux:Boot run it
   $ ssh … 'pgrep -c sshd'            # back to serving
   ```

   The mount's `Restart=always` brings the sshfs tunnel back within its 30 s retry window,
   so no action is needed on this machine.

Once Termux:Boot is in place, a reboot needs no intervention: the phone rejoins the
network, `sshd` starts, and the mount reconnects. What is *not* covered is `Termux` being
force-stopped or its data cleared.

## Troubleshooting

**`~/phone-termux` is empty or `ls` hangs.** The unit could not reach sshd. Check
`journalctl -u phone-termux-mount -e`; typical causes are Termux force-stopped by the
battery optimizer, or `sshd` never started. The unit retries every 30 s, so fixing the
phone is often enough; otherwise:

```console
$ sudo systemctl restart phone-termux-mount
```

**Worked, then hung after replugging the phone.** The unit notices the sshfs process
dying when the forward goes away and restarts, re-creating the forward first. If it does
not recover, `sudo systemctl restart phone-termux-mount`.

**Both USB and Wi-Fi are attached.** Every unit and script resolves one transport
explicitly (`PHONE_SERIAL`, else the configured Wi-Fi serial, else the only device,
else USB), because bare `adb` refuses to choose: `adb: more than one device/emulator`.

**Slow directory listing.** Termux' home often holds huge trees (an Android SDK, for
example). Browse targeted paths; do not `du -sh` the mount.

**Unmounting by hand** (as your user, if you mounted it yourself) needs the setuid
helper on NixOS, because the store copy of `fusermount3` cannot unmount:

```console
$ /run/wrappers/bin/fusermount3 -u ~/phone-termux
```

## When the phone goes away

sshfs is started with `reconnect`, which is what makes a short network hiccup
survivable — but it also means sshfs does **not** exit when sshd dies or the phone drops
off the network. The unit keeps saying `active` while the mount answers nothing.

The watchdog closes that gap. Every `watchdog.interval` it runs

```console
ssh -p 8022 … u0_a514@192.168.77.232 true
```

as root with the mount's key. If that fails **and** the unit is `active`, it restarts
`phone-termux-mount.service`; the restart re-runs `ExecStartPre`, which starts sshd over
the bridge if adb can reach the phone, then sshfs mounts again. A unit that is already
failing and retrying (`activating`) is left alone, so a phone that stays off does not
cause a restart every two minutes.

The consequence: a dead mount heals within one interval instead of waiting for some
unrelated access to trip over it. Check it with:

```console
$ systemctl list-timers phone-termux-mount-watchdog
$ journalctl -u phone-termux-mount-watchdog -n 20
```

## Security notes

- Host keys are not verified (`StrictHostKeyChecking=no`, `UserKnownHostsFile=/dev/null`)
  because the only route is the loopback adb forward; the transport is USB, and the
  alternative is pinning `/dev/null`-grade trust anyway. If you tunnel over a network
  instead, set `extraOptions = [ "StrictHostKeyChecking=yes" ]` and give root a known_hosts.
- Everything with access to the local adb server can do the same thing by hand. This
  module automates it, it does not widen access.
- `identityFile` must be readable by the mounting user and have no passphrase, since the mount happens unattended. Use a key dedicated to this mount.

## Standalone helper

The pre-mount script is exposed as a package for debugging:

```console
$ nix run github:MBanucu/phone-termux-mount#phone-termux-link
$ PHONE_PORT=8022 PHONE_USER=u0_a514 nix run .#phone-termux-link

$ nix run github:MBanucu/phone-termux-mount#phone-connect
```
