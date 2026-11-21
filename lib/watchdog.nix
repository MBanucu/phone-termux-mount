# sshfs with `reconnect` does not exit when the remote sshd goes away: it waits,
# so the unit stays "active" with a dead mount. This probe notices that and
# restarts the unit, which re-runs its own checks and resyncs the mount.
#
# Only a unit that claims to be active is restarted; a unit already failing and
# retrying is left to its own Restart= loop, so an absent phone does not cause
# restart storms.
{
  pkgs,
  unit,
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
      pkgs.gawk
      pkgs.gnugrep
    ]
  }:$PATH

  if ssh -p ${toString port} \
      -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -i ${pkgs.lib.escapeShellArg (toString identityFile)} \
      ${pkgs.lib.escapeShellArg "${remoteUser}@${host}"} true 2>/dev/null; then
    exit 0
  fi

  state=$(${systemdPackage}/bin/systemctl is-active ${unit} || true)
  if [ "$state" != "active" ]; then
    echo "sshd unreachable, ${unit} is '$state' — leaving it to its own retries"
    exit 0
  fi

  echo "sshd on ${host}:${toString port} stopped answering; restarting ${unit}"
  ${systemdPackage}/bin/systemctl restart ${unit}
''
