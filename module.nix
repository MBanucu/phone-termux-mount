{ config, lib, pkgs, ... }:

let
  cfg = config.services.phoneTermuxMount;

  username = cfg.user;

  # The login name must live in the host spec; sshfs rejects `-o User=`.
  # In direct mode the phone's sshd is reached over the network, so no adb
  # forward is involved at all.
  what =
    if cfg.transport == "direct" then
      "${cfg.remoteUser}@${if cfg.wifi.host != "" then cfg.wifi.host else cfg.sshHost}:${cfg.remotePath}"
    else
      "${cfg.remoteUser}@${cfg.sshHost}:${cfg.remotePath}";

  # No uid=/gid= here on purpose: NixOS assigns normal-user ids at activation,
  # so config.users.users.<name>.uid may be null at eval time. Running sshfs as
  # the user gets correct ownership from idmap=user without needing the number.
  mountOptions = lib.concatStringsSep "," (
    [
      "reconnect"
      "ServerAliveInterval=15"
      "ServerAliveCountMax=3"
      "follow_symlinks"
      "idmap=user"
      "Port=${toString cfg.port}"
      "IdentityFile=${cfg.identityFile}"
      "IdentitiesOnly=yes"
      "Compression=no"
      # Over the adb forward this checks nothing but that 127.0.0.1 is
      # 127.0.0.1; in direct mode the phone's key is not managed by this
      # module, so the same setting applies. Pin a known_hosts file via
      # extraOptions if you want verification.
      "StrictHostKeyChecking=no"
      "UserKnownHostsFile=/dev/null"
    ]
    ++ cfg.extraOptions
  );

  wifiSerial = if cfg.wifi.enable then "${cfg.wifi.host}:${toString cfg.wifi.port}" else null;

  # Only built when Wi-Fi is on, so wifi.host stays unevaluated otherwise.
  connectScript =
    if cfg.wifi.enable then
      import ./lib/connect.nix {
        inherit pkgs;
        inherit (cfg.wifi) host port;
        bootstrapUsb = cfg.wifi.bootstrapUsb;
      }
    else
      null;

  linkScript = import ./lib/ensure-link.nix {
    inherit pkgs;
    inherit (cfg) port remoteUser identityFile startSshd;
    host = cfg.sshHost;
    inherit wifiSerial connectScript;
  };
in
{
  options.services.phoneTermuxMount = {
    enable = lib.mkEnableOption ''
      mounting a Termux home directory from an adb-connected Android phone over sshfs,
      with the adb forward and sshd kept alive by systemd'';

    user = lib.mkOption {
      type = lib.types.str;
      description = "Local account that owns the mount and runs both sshfs and the adb forward.";
      example = "michi";
    };

    remoteUser = lib.mkOption {
      type = lib.types.str;
      description = ''
        Termux's Linux user name on the phone. Find it by opening Termux and
        running `whoami`.
      '';
      example = "u0_a514";
    };

    sshHost = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Host the adb forward listens on. Loopback is the normal case over USB.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 8022;
      description = "Port for the adb forward and Termux's sshd (both sides use the same number).";
    };

    remotePath = lib.mkOption {
      type = lib.types.str;
      default = "/data/data/com.termux/files/home";
      description = "Directory on the phone to mount.";
    };

    mountpoint = lib.mkOption {
      type = lib.types.str;
      default = "/home/${cfg.user}/phone-termux";
      description = "Local mountpoint. Created automatically, owned by `user`.";
    };

    identityFile = lib.mkOption {
      type = lib.types.path;
      default = "/home/${cfg.user}/.ssh/id_ed25519_phone";
      description = ''
        Private key authorized in Termux's ~/.ssh/authorized_keys. Read by the
        mounting user, so a passphrase-free key is required for unattended mounts.
      '';
    };

    startSshd = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        If sshd does not answer, ask the `com.termux.adbbridge` helper app to start
        it, instead of failing immediately. Set to false if that app is not installed.
      '';
    };

    extraOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra comma-separated options passed to sshfs.";
      example = [ "cache=yes" ];
    };

    transport = lib.mkOption {
      type = lib.types.enum [
        "adb"
        "direct"
      ];
      default = "adb";
      description = ''
        How sshfs reaches the phone.

        `adb` goes through an adb forward on 127.0.0.1, so it works over USB and,
        with `wifi.enable`, over the network as well.

        `direct` connects straight to the phone's sshd on its network address
        (`wifi.host`), with no adb involvement at all: nothing to keep alive, no
        forward to rebuild, and no TCP adb port exposed. Requires sshd to run on
        the phone, e.g. started at boot by Termux:Boot.
      '';
    };

    wifi = {
      enable = lib.mkEnableOption ''
        using adb over Wi-Fi instead of the USB cable: the transport is brought up
        before mounting and preferred over USB when it is available'';

      host = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = ''
          The phone's address on the network, as seen from this machine — the
          hotspot address when it shares one, e.g. 10.223.158.226.
        '';
        example = "10.223.158.226";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 5555;
        description = ''
          Port adbd listens on in TCP mode. Classic `adb tcpip` mode, not the
          randomised port of Android's Wireless-debugging toggle.
        '';
      };

      bootstrapUsb = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          If nothing listens on the TCP port yet but the phone is on USB, run
          `adb tcpip` to switch adbd into TCP mode. adbd returns to USB-only after
          the phone reboots.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.wifi.enable -> cfg.wifi.host != "";
        message = "services.phoneTermuxMount.wifi.host must be the phone's network address when wifi.enable is on.";
      }
      {
        assertion = cfg.transport != "direct" || cfg.wifi.host != "";
        message = "services.phoneTermuxMount.wifi.host must be set when transport = \"direct\".";
      }
    ];

    # `programs.adb` was removed in NixOS 26.05 (systemd 258 ships the uaccess
    # rule itself), so adb only needs to be on PATH, which this does.
    environment.systemPackages = [
      pkgs.android-tools
      pkgs.openssh
      pkgs.sshfs
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.mountpoint} 0755 ${username} - -"
    ];

    # One unit, run as the user: the pre-start step establishes the adb forward
    # (using the user's adb server, so no root adb race for the USB device), then
    # sshfs mounts. Because the pre-start runs on every restart, a replugged or
    # rebooted phone heals without manual action.
    systemd.services.phone-termux-mount = {
      description =
        if cfg.transport == "direct" then
          "Termux home from the phone (sshfs over Wi-Fi)"
        else
          "Termux home from the phone (sshfs over adb)";
      wantedBy = [ "multi-user.target" ];
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Type = "simple";
        User = username;
        # Direct mode talks to the phone's own sshd, so there is no forward to
        # create: the only prerequisite is that sshd is up, and sshfs retries
        # every RestartSec until it is.
        ExecStartPre = lib.optional (cfg.transport == "adb") linkScript;
        ExecStart = lib.escapeShellArgs [
          "${pkgs.sshfs}/bin/sshfs"
          what
          cfg.mountpoint
          "-o"
          mountOptions
          "-f"
        ];
        ExecStop = "${config.security.wrapperDir}/fusermount3 -u ${cfg.mountpoint}";
        Restart = "always";
        RestartSec = "30s";
      };
    };
  };
}
