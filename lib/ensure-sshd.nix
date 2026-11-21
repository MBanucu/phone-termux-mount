# Checks that the phone's sshd answers, and tries to start it through the
# termux-adb-bridge app when it does not. Used as ExecStartPre in direct mode so
# a mount attempt either succeeds or fails fast with a clear reason, instead of
# hanging on a dead sshd.
{
  pkgs,
  host,
  port ? 8022,
  remoteUser,
  identityFile,
  startSshd ? true,
}:
pkgs.writeShellScript "phone-termux-ensure-sshd" ''
  set -eu

  export PATH=${
    pkgs.lib.makeBinPath [
      pkgs.android-tools
      pkgs.openssh
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
    ]
  }:$PATH

  probe() {
    ssh -p ${toString port} \
      -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      -i ${pkgs.lib.escapeShellArg (toString identityFile)} \
      ${pkgs.lib.escapeShellArg "${remoteUser}@${host}"} true 2>/dev/null
  }

  if probe; then
    exit 0
  fi

  echo "sshd is not answering on ${host}:${toString port}"
  ${
    if startSshd then
      ''
        serial=$(adb devices | awk 'NR>1 && $2 == "device" { print $1; exit }')
        if [ -n "$serial" ]; then
          echo "asking Termux to start sshd over adb ($serial)"
          adb -s "$serial" shell am start \
            -n com.termux.adbbridge/.Bridge --es cmd 'sshd' >/dev/null 2>&1 || true
          for _ in $(seq 1 10); do
            sleep 1
            if probe; then
              echo "sshd answered after being started over adb"
              exit 0
            fi
          done
        else
          echo "no adb device to start sshd through" >&2
        fi
      ''
    else
      ""
  }

  echo "error: cannot reach sshd at ${remoteUser}@${host}:${toString port}" >&2
  echo "  - is Termux running (not force-stopped)?" >&2
  echo "  - is Termux:Boot installed, with ~/.termux/boot/start-sshd?" >&2
  exit 1
''
