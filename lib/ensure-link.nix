# Ensures the adb forward exists and Termux's sshd answers before sshfs mounts.
# Every value can be overridden at runtime through PHONE_* environment variables,
# which keeps the built script usable for debugging outside systemd.
{
  pkgs,
  port ? 8022,
  host ? "127.0.0.1",
  remoteUser ? "u0_a514",
  identityFile ? null,
  startSshd ? true,
}:
pkgs.writeShellScript "phone-termux-link" ''
  set -eu

  port="''${PHONE_PORT:-${toString port}}"
  host="''${PHONE_HOST:-${host}}"
  remote_user="''${PHONE_USER:-${remoteUser}}"
  key="''${PHONE_KEY:-${if identityFile == null then "" else toString identityFile}}"

  adb=${pkgs.android-tools}/bin/adb
  ssh=${pkgs.openssh}/bin/ssh

  check() {
    $ssh -p "$port" \
      -o BatchMode=yes -o ConnectTimeout=4 \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      ''${key:+-i "$key"} \
      "$remote_user@$host" true 2>/dev/null
  }

  echo "waiting for an adb device…"
  if ! timeout 30 "$adb" wait-for-device; then
    echo "error: no adb device. Plug the phone in and authorize this computer:" >&2
    echo "  adb devices" >&2
    exit 1
  fi

  "$adb" forward "tcp:$port" "tcp:$port" >/dev/null
  echo "adb forward tcp:$port -> tcp:$port established"

  if check; then
    echo "sshd answered on port $port"
    exit 0
  fi
  ${
    if startSshd then
      ''
        echo "sshd did not answer, asking Termux to start it (needs com.termux.adbbridge)"
        "$adb" shell am start -n com.termux.adbbridge/.Bridge --es cmd 'sshd' >/dev/null 2>&1 || true
        for _ in $(seq 1 20); do
          sleep 1
          if check; then
            echo "sshd answered on port $port"
            exit 0
          fi
        done
      ''
    else
      ""
  }

  echo "error: cannot reach sshd at $remote_user@$host:$port" >&2
  echo "  - is Termux running (not force-stopped)?" >&2
  echo "  - open Termux and run: sshd" >&2
  ${if startSshd then ''echo "  - or install com.termux.adbbridge so this unit can start it" >&2'' else ""}
  echo "  - does ~/.ssh/authorized_keys in Termux contain this computer's key?" >&2
  exit 1
''
