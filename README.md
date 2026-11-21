# phone-termux-mount

NixOS module that mounts a Termux home directory from an adb-connected Android phone
over sshfs — with on-demand automount and a systemd unit that keeps the `adb forward`
(and Termux's `sshd`) alive.

```console
$ ls ~/phone-termux            # triggers the automount
android-sdk  go  projects      # Termux' own home, as a normal directory
```

No root on the phone, no debuggable Termux, no Samba: it is plain SSH over the adb
forward you would otherwise set up by hand.

## What it sets up

| Piece | Purpose |
|---|---|
| `phone-termux-link.service` | runs as your user: waits for the phone, creates `adb forward tcp:8022 tcp:8022`, checks that sshd answers, and optionally asks the [`termux-adb-bridge`](https://github.com/MBanucu/termux-adb-bridge) app to start it |
| `<mountpoint>.mount` | root-owned `fuse.sshfs` mount of `/data/data/com.termux/files/home`, `Requires=` the link unit |
| `<mountpoint>.automount` | mounts on first access, unmounts again after `idleTimeout` |

The mount itself runs as root (that is the normal systemd mount model), so it does not
depend on a login session; files are presented as your user via `uid=`/`gid=`.

## Requirements

On the phone, once:

1. Termux installed, with `sshd` available: `pkg install openssh`.
2. An SSH key from this machine in `~/.ssh/authorized_keys` (chmod 600).
   If you use the mount only, a key without a passphrase is what you want, since the
   mount happens in the background.
3. Optional but recommended: [`com.termux.adbbridge`](https://github.com/MBanucu/termux-adb-bridge)
   installed and granted, so `startSshd` can restart `sshd` without you touching the phone.

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
| `user` | — | local account owning the mountpoint, running the adb forward |
| `remoteUser` | — | Termux's Linux user (`whoami` in Termux, e.g. `u0_a514`) |
| `sshHost` | `"127.0.0.1"` | host of the adb forward |
| `port` | `8022` | sshd and forward port |
| `remotePath` | `/data/data/com.termux/files/home` | directory to mount |
| `mountpoint` | `/home/<user>/phone-termux` | where it appears locally |
| `identityFile` | `/home/<user>/.ssh/id_ed25519_phone` | key authorized in Termux |
| `startSshd` | `true` | ask the bridge app to start sshd when it does not answer |
| `extraOptions` | `[]` | extra sshfs options, e.g. `[ "cache=yes" ]` |
| `idleTimeout` | `"60s"` | automount idle timeout |

## Using it

```console
$ ls ~/phone-termux                    # mount on demand
$ systemctl status phone-termux-link   # did the forward/sshd step work?
$ journalctl -u phone-termux-link -e   # its log
```

Unit names contain the escaped path, so target them by pattern:

```console
$ systemctl list-units 'home-*phone*'
$ sudo systemctl restart "$(systemd-escape -p --suffix=mount ~/phone-termux)"
```

## Troubleshooting

**`ls` hangs, then fails.** The link unit could not reach sshd. Check
`journalctl -u phone-termux-link -e`; typical causes are Termux force-stopped by the
battery optimizer, or `sshd` never started. Reset and retry:

```console
$ sudo systemctl reset-failed phone-termux-link.service
$ sudo systemctl restart phone-termux-link.service
```

**Worked, then hung after replugging the phone.** The forward died with the adb
server. The mount has `reconnect`, so it recovers once the forward is back:

```console
$ sudo systemctl restart phone-termux-link.service
```

**Slow directory listing.** Termux' home often holds huge trees (an Android SDK, for
example). Browse targeted paths; do not `du -sh` the mount.

**Unmounting by hand** (as your user, if you mounted it yourself) needs the setuid
helper on NixOS, because the store copy of `fusermount3` cannot unmount:

```console
$ /run/wrappers/bin/fusermount3 -u ~/phone-termux
```

## Security notes

- Host keys are not verified (`StrictHostKeyChecking=no`, `UserKnownHostsFile=/dev/null`)
  because the only route is the loopback adb forward; the transport is USB, and the
  alternative is pinning `/dev/null`-grade trust anyway. If you tunnel over a network
  instead, set `extraOptions = [ "StrictHostKeyChecking=yes" ]` and give root a known_hosts.
- Everything with access to the local adb server can do the same thing by hand. This
  module automates it, it does not widen access.
- `identityFile` is read by root at mount time. Use a key dedicated to this mount.

## Standalone helper

The pre-mount script is exposed as a package for debugging:

```console
$ nix run github:MBanucu/phone-termux-mount#phone-termux-link
$ PHONE_PORT=8022 PHONE_USER=u0_a514 nix run .#phone-termux-link
```
