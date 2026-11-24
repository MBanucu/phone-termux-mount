# Exercises the two self-heal scripts without a phone, a FUSE mount, systemd or
# root, which is what `nix flake check` can offer: both scripts take the
# commands they call as arguments, so the check points them at stubs that record
# what was called and are told whether to fail. What remains under test is the
# logic that actually breaks on a real machine — which condition triggers a
# restart, and whether a stale mountpoint is cleared before sshfs sees it.
{ pkgs }:
let
  mountpoint = "/run/check-mountpoint";

  stubs = pkgs.runCommand "phone-termux-fake-tools" { } ''
    mkdir -p $out

    cat > $out/findmnt <<'EOF'
    #!/bin/sh
    # -n -T <path> -o TARGET: FAKE_MOUNT_TARGET when mounted, / otherwise.
    printf '%s\n' "''${FAKE_MOUNT_TARGET:-/}"
    EOF

    cat > $out/fusermount <<'EOF'
    #!/bin/sh
    echo "fusermount $*" >> "''${FAKE_LOG:?}"
    case "''${FAKE_FUSERMOUNT:-ok}" in
      ok) exit 0 ;;
      # Plain -u refused, -uz works: the fallback it has to take.
      zu-only) [ "$1" = -uz ] ;;
      fail) exit 1 ;;
    esac
    EOF

    cat > $out/systemctl <<'EOF'
    #!/bin/sh
    if [ "$1" = restart ]; then
      echo "systemctl restart $2" >> "''${FAKE_LOG:?}"
      exit 0
    fi
    printf '%s\n' "''${FAKE_UNIT_STATE:-active}"
    EOF

    cat > $out/ssh <<'EOF'
    #!/bin/sh
    exit "''${FAKE_SSH_RC:-0}"
    EOF

    cat > $out/runuser <<'EOF'
    #!/bin/sh
    # -u USER -- CMD: run CMD, or report the EACCES/ENOTCONN it would give.
    shift 3
    [ "''${FAKE_MOUNT_RC:-0}" = 0 ] || exit "''${FAKE_MOUNT_RC}"
    exec "$@"
    EOF

    chmod +x $out/*
  '';

  prepare = import ./lib/prepare-mountpoint.nix {
    inherit pkgs mountpoint;
    fusermount = "${stubs}/fusermount";
    findmnt = "${stubs}/findmnt";
  };

  watchdog = import ./lib/watchdog.nix {
    inherit pkgs mountpoint;
    unit = "phone-termux-mount.service";
    user = "test";
    systemdPackage = pkgs.systemd;
    systemctl = "${stubs}/systemctl";
    ssh = "${stubs}/ssh";
    runuser = "${stubs}/runuser";
    host = "192.0.2.1";
    remoteUser = "u0_a1";
    identityFile = "/dev/null";
  };
in
pkgs.runCommand "phone-termux-self-heal-check" { } ''
  set -eu
  export FAKE_LOG=$TMPDIR/calls
  mp=$TMPDIR/mnt

  fail() {
    echo "FAIL: $*" >&2
    exit 1
  }

  prep() {
    FAKE_MOUNT_TARGET=$1 FAKE_FUSERMOUNT=$2 PHONE_MOUNTPOINT=$mp ${prepare}
  }

  # A unit that is not active is left to its own Restart= loop, so the probes
  # below are only reached while the unit claims to be active.
  wd() {
    FAKE_UNIT_STATE=$1 FAKE_SSH_RC=$2 FAKE_MOUNT_RC=$3 PHONE_MOUNTPOINT=$mp ${watchdog}
  }

  restarts() {
    grep -c '^systemctl restart' "$FAKE_LOG" || true
  }

  echo "--- preparer: nothing mounted ---"
  : > "$FAKE_LOG"
  prep / ok
  [ -d "$mp" ] || fail "did not create $mp"
  [ ! -s "$FAKE_LOG" ] || fail "unmounted although nothing was mounted: $(cat "$FAKE_LOG")"

  echo "--- preparer: a mount left behind is cleared first ---"
  : > "$FAKE_LOG"
  prep "$mp" ok
  grep -qxF "fusermount -u $mp" "$FAKE_LOG" || fail "did not clear $mp: $(cat "$FAKE_LOG")"

  echo "--- preparer: falls back to -uz ---"
  : > "$FAKE_LOG"
  prep "$mp" zu-only
  grep -qxF "fusermount -uz $mp" "$FAKE_LOG" || fail "no fallback: $(cat "$FAKE_LOG")"

  echo "--- preparer: an endpoint it cannot clear stops the start ---"
  : > "$FAKE_LOG"
  if msg=$(prep "$mp" fail 2>&1); then
    fail "let sshfs start on a mountpoint it could not clear"
  fi
  case "$msg" in
    *"could not unmount"*"-uz"*) ;;
    *) fail "gave no way out: $msg" ;;
  esac

  echo "--- watchdog: healthy mount is left alone ---"
  : > "$FAKE_LOG"
  wd active 0 0
  [ "$(restarts)" = 0 ] || fail "restarted a healthy mount"

  echo "--- watchdog: a unit already retrying is left alone ---"
  : > "$FAKE_LOG"
  msg=$(wd activating 0 0 2>&1)
  [ "$(restarts)" = 0 ] || fail "restarted a unit that is already retrying"
  case "$msg" in
    *"leaving it to its own retries"*) ;;
    *) fail "unexpected output: $msg" ;;
  esac

  echo "--- watchdog: sshd gone restarts ---"
  : > "$FAKE_LOG"
  wd active 1 0
  [ "$(restarts)" = 1 ] || fail "did not restart when sshd stopped answering"

  echo "--- watchdog: a dead mount restarts even though sshd answers ---"
  : > "$FAKE_LOG"
  wd active 0 1
  [ "$(restarts)" = 1 ] || fail "did not restart when only the mount was dead"

  # Never name a variable `out`: the builder's $out is where this has to write.
  touch "$out"
''
