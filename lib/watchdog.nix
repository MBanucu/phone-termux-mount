# sshfs with `reconnect` does not exit when the remote sshd goes away: it waits,
# so the unit stays "active" with a dead mount. This probe notices that and
# restarts the unit, which re-runs its own checks and resyncs the mount.
#
# Two things can be dead while the unit claims to be active: the tunnel (sshd
# stopped answering) and the mount itself (sshfs died, or the kernel dropped the
# FUSE connection, leaving a "Transport endpoint is not connected" endpoint).
# The second case is why probing only sshd is not enough — sshd can answer
# perfectly while the mountpoint is dead, which is exactly what a stale mount
# from a previous sshfs looks like. The restart now clears that first.
#
# Only a unit that claims to be active is restarted; a unit already failing and
# retrying is left to its own Restart= loop, so an absent phone does not cause
# restart storms.
{
  pkgs,
  unit,
  mountpoint,
  # The mount belongs to this user, and FUSE without allow_other refuses even
  # root, so the mountpoint has to be probed as this user.
  user,
  systemdPackage,
  host,
  port ? 8022,
  remoteUser,
  identityFile,
}:
pkgs.writeShellScript "phone-termux-watchdog" ''
  set -eu

  export PATH=${
    pkgs.lib.makeBinPath [
      pkgs.openssh
      pkgs.coreutils
      pkgs.util-linux
      pkgs.gawk
      pkgs.gnugrep
    ]
  }:$PATH

  mp="''${PHONE_MOUNTPOINT:-${mountpoint}}"

  restart() {
    echo "$1; restarting ${unit}"
    ${systemdPackage}/bin/systemctl restart ${unit}
  }

  state=$(${systemdPackage}/bin/systemctl is-active ${unit} || true)
  if [ "$state" != "active" ]; then
    echo "${unit} is '$state' — leaving it to its own retries"
    exit 0
  fi

  # The tunnel first: if sshd is gone the mount check below would only hang
  # until its timeout and report the same thing.
  if ! ssh -p ${toString port} \
      -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -i ${pkgs.lib.escapeShellArg (toString identityFile)} \
      ${pkgs.lib.escapeShellArg "${remoteUser}@${host}"} true 2>/dev/null; then
    restart "sshd on ${host}:${toString port} stopped answering"
    exit 0
  fi

  # sshd answers, so the tunnel is fine — but the mount can still be dead. A
  # single getattr on the mountpoint hangs when the FUSE connection is gone and
  # fails at once when it is a stale endpoint; either way it is not a mount we
  # can use. This runs as the mounting user: the mount is not allow_other, so
  # root gets EACCES on a perfectly healthy mount.
  if ! runuser -u ${pkgs.lib.escapeShellArg user} -- \
      timeout 10 stat -c %d "$mp" >/dev/null 2>&1; then
    restart "sshfs on $mp is not answering (dead or stale mount)"
  fi
''
