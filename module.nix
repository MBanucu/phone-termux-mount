{ config, lib, pkgs, ... }:

let
  cfg = config.services.phoneTermuxMount;

  username = cfg.user;

  # The login name must live in the host spec; sshfs rejects `-o User=`.
  what = "${cfg.remoteUser}@${cfg.sshHost}:${cfg.remotePath}";

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
      # The only route is the loopback adb forward, so host key verification
      # would check nothing but that 127.0.0.1 is 127.0.0.1.
      "StrictHostKeyChecking=no"
      "UserKnownHostsFile=/dev/null"
    ]
    ++ cfg.extraOptions
  );

  linkScript = import ./lib/ensure-link.nix {
    inherit pkgs;
    inherit (cfg) port remoteUser identityFile startSshd;
    host = cfg.sshHost;
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
  };

  config = lib.mkIf cfg.enable {
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
      description = "Termux home from the phone (sshfs over adb)";
      wantedBy = [ "multi-user.target" ];
      unitConfig.StartLimitIntervalSec = 0;
      serviceConfig = {
        Type = "simple";
        User = username;
        ExecStartPre = linkScript;
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
