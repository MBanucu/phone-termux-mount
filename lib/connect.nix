# Establishes an adb transport to the phone over the network, so the mount and
# phone-cmd work without a cable.
#
# Order of attempts:
#   1. already connected over TCP -> nothing to do
#   2. `adb connect` to PHONE_HOST / the baked host
#   3. otherwise look for the phone among the Wi-Fi neighbours (ARP table)
#   4. if still nothing and the phone is on USB, `adb tcpip` to switch adbd into
#      TCP mode, then retry (adbd returns to USB-only after a reboot)
{
  pkgs,
  host ? "",
  port ? 5555,
  bootstrapUsb ? true,
}:
pkgs.writeShellScript "phone-connect" ''
  set -eu

  export PATH=${
    pkgs.lib.makeBinPath [
      pkgs.android-tools
      pkgs.iproute2
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
    ]
  }:$PATH

  port="''${PHONE_PORT:-${toString port}}"
  host="''${PHONE_HOST:-${host}}"

  wifi_serial() {
    adb devices | awk 'NR>1 && $2 == "device" && $1 ~ /:/ { print $1; exit }'
  }

  try_host() {
    candidate="$1:$port"
    adb connect "$candidate" >/dev/null 2>&1 || true
    # adb connect returns before the handshake settles; ask adb for the truth.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if [ "$(wifi_serial)" = "$candidate" ]; then
        echo "connected to $candidate"
        return 0
      fi
      sleep 0.3
    done
    adb disconnect "$candidate" >/dev/null 2>&1 || true
    return 1
  }

  if [ -n "$(wifi_serial)" ]; then
    echo "already connected over Wi-Fi: $(wifi_serial)"
    exit 0
  fi

  # Candidates: the configured host first, then the neighbours we have talked
  # to on the Wi-Fi link, so a DHCP change that moved the phone does not need a
  # config edit. The default route is no help here: USB tethering installs one
  # too, and connecting through it would still depend on the cable.
  wl=$(ls /sys/class/net 2>/dev/null | grep '^wl' | head -n 1 || true)
  neighbours=""
  if [ -n "$wl" ]; then
    neighbours=$(ip neigh show dev "$wl" 2>/dev/null | awk '$1 ~ /^[0-9]+\./ { print $1 }')
  fi

  candidates="$host"
  for neighbour in $neighbours; do
    if [ "$neighbour" != "$host" ]; then
      candidates="$candidates $neighbour"
    fi
  done
  candidates=$(printf '%s\n' $candidates)

  if [ -z "$candidates" ]; then
    echo "error: no candidate address. Set PHONE_HOST to the phone's Wi-Fi address." >&2
  else
    for candidate in $candidates; do
      echo "trying $candidate:$port"
      if try_host "$candidate"; then
        exit 0
      fi
    done
  fi

  if [ ${if bootstrapUsb then "1" else "0"} = 1 ]; then
    usb=$(adb devices | awk 'NR>1 && $2 == "device" && $1 !~ /:/ { print $1; exit }')
    if [ -n "$usb" ]; then
      echo "no listener on port $port yet; enabling it over USB ($usb)"
      adb -s "$usb" tcpip "$port" >/dev/null 2>&1 || true
      sleep 2
      for candidate in $candidates; do
        if try_host "$candidate"; then
          exit 0
        fi
      done
    fi
  fi

  echo "error: no adb transport over Wi-Fi" >&2
  echo "  - is the phone on the same network as this machine?" >&2
  echo "  - plug in USB once and run this again to switch adbd to TCP mode" >&2
  exit 1
''
