{ config, lib, pkgs, ... }:

let
  cfg = config.services.phoneTermuxMount;

  username = cfg.user;
  user = config.users.users.${username};

  # Primary group of the account, if NixOS knows about it.
  knownGroup =
    let
      group = user.group or "";
    in
    group != "" && builtins.hasAttr group config.users.groups;

  groupName = if knownGroup then user.group else "-";

  # Primary GID: the account's group if known, else the UID.
  gid = if knownGroup then config.users.groups.${user.group}.gid else user.uid;

  mountOptions = lib.concatStringsSep "," (
    [
      "reconnect"
      "ServerAliveInterval=15"
      "ServerAliveCountMax=3"
      "follow_symlinks"
      "idmap=user"
      "uid=${toString user.uid}"
      "gid=${toString gid}"
      "Port=${toString cfg.port}"
      "IdentityFile=${cfg.identityFile}"
      "IdentitiesOnly=yes"
      "Compression=no"
      # Termux sshd is reachable only through the loopback adb forward, so host
      # key verification would just be checking that 127.0.0.1 is 127.0.0.1.
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
      with on-demand automount and an adb forward maintained by systemd'';

    user = lib.mkOption {
      type = lib.types.str;
      description = "Local account that owns the mountpoint and runs the adb forward.";
      example = "michi";
    };

    remoteUser = lib.mkOption {
      type = lib.types.str;
      description = ''
        Termux's Linux user name on the phone. Find it by opening Termux and
        running `whoami`, or `stat -c %U ~`.
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
        Private key authorized in Termux's ~/.ssh/authorized_keys. Read by root at
        mount time, so it must be readable by root (normal for a 0600 key in a home dir).
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

    idleTimeout = lib.mkOption {
      type = lib.types.str;
      default = "60s";
      description = "Unmount after this long with no access (systemd automount TimeoutIdleSec).";
    };
  };

  config = lib.mkIf cfg.enable {
    # udev rules so the phone is accessible to the adb server without root.
    programs.adb.enable = lib.mkDefault true;

    environment.systemPackages = [
      pkgs.android-tools
      pkgs.openssh
      pkgs.sshfs
    ];

    # The mountpoint must exist and belong to the user before automount can fire.
    systemd.tmpfiles.rules = [
      "d ${cfg.mountpoint} 0755 ${username} ${groupName} -"
    ];

    systemd.services.phone-termux-link = {
      description = "Ensure adb forward and SSH access to Termux on the phone";
      # Runs as the user so it reuses the user's adb server (a root adb server
      # would fight it for the USB device); the forward it creates is on the
      # loopback, so the root-owned sshfs mount can still connect to it.
      serviceConfig = {
        Type = "oneshot";
        User = username;
        ExecStart = linkScript;
        # Bind to the phone link, not the network stack.
        TimeoutStartSec = "90s";
      };
    };

    systemd.mounts = [
      {
        description = "Termux home on the phone (sshfs)";
        # sshfs rejects `-o User=`; the login name must live in the host spec.
        what = "${cfg.remoteUser}@${cfg.sshHost}:${cfg.remotePath}";
        where = cfg.mountpoint;
        type = "fuse.sshfs";
        options = mountOptions;
        requires = [ "phone-termux-link.service" ];
        after = [ "phone-termux-link.service" ];
      }
    ];

    systemd.automounts = [
      {
        where = cfg.mountpoint;
        wantedBy = [ "multi-user.target" ];
        automountConfig.TimeoutIdleSec = cfg.idleTimeout;
      }
    ];

    assertions = [
      {
        assertion = config.users.users ? ${username};
        message = "services.phoneTermuxMount.user = \"${username}\" is not a local user.";
      }
    ];
  };
}
