# sshfs that dies without unmounting leaves a dead FUSE endpoint behind, and
# sshfs then refuses to mount over it:
#
#   fuse: failed to access mountpoint …: Transport endpoint is not connected
#
# Because the command that fails is ExecStart, systemd never reaches ExecStop,
# which is the only place that would unmount — so the unit retries every
# RestartSec forever and one killed sshfs poisons the mountpoint until someone
# clears it by hand. This runs before sshfs and makes the retry loop heal.
{
  pkgs,
  mountpoint,
  # The store copy of fusermount3 cannot unmount; the setuid wrapper can.
  fusermount ? "${pkgs.fuse3}/bin/fusermount3",
  # Only replaced to exercise this without a FUSE mount; see checks.nix.
  findmnt ? "${pkgs.util-linux}/bin/findmnt",
}:
pkgs.writeShellScript "phone-termux-prepare-mountpoint" ''
  set -eu

  # findmnt reads the mount table; `mountpoint` would stat the path instead and
  # report "not a mountpoint" for exactly the stale endpoint this has to find.
  export PATH=${pkgs.coreutils}/bin:$PATH

  mp="''${PHONE_MOUNTPOINT:-${mountpoint}}"

  # -T resolves the containing mount for an ordinary directory, so compare the
  # target it reports rather than trusting that anything was found.
  if [ "$(${findmnt} -n -T "$mp" -o TARGET 2>/dev/null || true)" = "$mp" ]; then
    echo "clearing a mount left behind on $mp"
    ${fusermount} -u "$mp" 2>/dev/null || ${fusermount} -uz "$mp" 2>/dev/null || {
      echo "error: could not unmount $mp; clear it by hand:" >&2
      echo "  ${fusermount} -uz $mp" >&2
      exit 1
    }
  fi

  # Unmount before mkdir: even that fails with ENOTCONN while a dead endpoint
  # still sits on the path.
  mkdir -p "$mp"

  # Fail with the fix instead of letting sshfs report ENOTCONN again.
  if ! timeout 10 ls "$mp" >/dev/null 2>&1; then
    echo "error: $mp is still a dead mountpoint; unmount it by hand:" >&2
    echo "  ${fusermount} -uz $mp" >&2
    exit 1
  fi
''
