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
  # When set, "<host>:<port>" of the Wi-Fi transport, which is preferred and
  # established through connectScript before anything else is tried.
  wifiSerial ? null,
  connectScript ? null,
}:
pkgs.writeShellScript "phone-termux-link" ''
  set -eu

  # systemd units run with a minimal PATH that does not include awk, grep, head,
  # seq or timeout, so provide them explicitly instead of assuming the caller's.
  export PATH=${
    pkgs.lib.makeBinPath [
      pkgs.android-tools
      pkgs.openssh
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
    ]
  }:$PATH

  port="''${PHONE_PORT:-${toString port}}"
  host="''${PHONE_HOST:-${host}}"
  remote_user="''${PHONE_USER:-${remoteUser}}"
  key="''${PHONE_KEY:-${if identityFile == null then "" else toString identityFile}}"

  adb=${pkgs.android-tools}/bin/adb
  ssh=${pkgs.openssh}/bin/ssh

  wifi_serial="''${PHONE_SERIAL:-${if wifiSerial == null then "" else wifiSerial}}"

  # A phone can be reachable over USB and Wi-Fi at the same time, and then plain
  # `adb` fails with "more than one device". Pick one transport explicitly:
  # an explicit serial, else the configured Wi-Fi transport, else the only
  # device, else USB (faster, and its forward is not affected by Wi-Fi drops).
  pick_device() {
    devices=$($adb devices | awk 'NR>1 && $2 == "device" { print $1 }')
    if [ -n "$wifi_serial" ] && printf '%s\n' "$devices" | grep -qx "$wifi_serial"; then
      echo "$wifi_serial"
      return 0
    fi
    count=$(printf '%s\n' "$devices" | grep -c . || true)
    case "$count" in
      0) return 1 ;;
      1) printf '%s\n' "$devices"; return 0 ;;
    esac
    # Wi-Fi is configured but the configured address is gone (a DHCP change):
    # take whatever network transport phone-connect managed to establish.
    if [ -n "$wifi_serial" ]; then
      tcp=$(printf '%s\n' "$devices" | grep ':' | head -n 1 || true)
      if [ -n "$tcp" ]; then
        echo "$tcp"
        return 0
      fi
    fi
    usb=$(printf '%s\n' "$devices" | grep -v ':' | head -n 1 || true)
    if [ -n "$usb" ]; then
      echo "$usb"
    else
      printf '%s\n' "$devices" | head -n 1
    fi
  }

  # Bring up the Wi-Fi transport first: phone-connect is idempotent and cheap
  # when it is already there, and it is what makes the mount prefer the network
  # over an attached cable.
  ${pkgs.lib.optionalString (connectScript != null) ''
    ${connectScript} || true
  ''}

  if ! serial=$(pick_device); then
    echo "waiting for an adb device…"
    if ! timeout 30 "$adb" wait-for-device; then
      echo "error: no adb device. Plug the phone in, or connect over Wi-Fi:" >&2
      echo "  adb connect <phone-ip>:5555" >&2
      exit 1
    fi
    serial=$(pick_device) || { echo "error: no usable adb device" >&2; exit 1; }
  fi
  echo "using adb device $serial"

  check() {
    $ssh -p "$port" \
      -o BatchMode=yes -o ConnectTimeout=4 \
      -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
      ''${key:+-i "$key"} \
      "$remote_user@$host" true 2>/dev/null
  }

  "$adb" -s "$serial" forward "tcp:$port" "tcp:$port" >/dev/null
  echo "adb forward tcp:$port -> tcp:$port established"

  if check; then
    echo "sshd answered on port $port"
    exit 0
  fi
  ${
    if startSshd then
      ''
        echo "sshd did not answer, asking Termux to start it (needs com.termux.adbbridge)"
        "$adb" -s "$serial" shell am start -n com.termux.adbbridge/.Bridge --es cmd 'sshd' >/dev/null 2>&1 || true
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
