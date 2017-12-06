{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.elasticsearch;

  es5 = builtins.compareVersions (builtins.parseDrvName cfg.package.name).version "5" >= 0;

  esConfig = ''
    network.host: ${cfg.listenAddress}
    cluster.name: ${cfg.cluster_name}

    ${if es5 then ''
      http.port: ${toString cfg.port}
      transport.tcp.port: ${toString cfg.tcp_port}
    '' else ''
      network.port: ${toString cfg.port}
      network.tcp.port: ${toString cfg.tcp_port}
      # TODO: find a way to enable security manager
      security.manager.enabled: false
    ''}

    ${cfg.extraConf}
  '';

  configDir = pkgs.buildEnv {
    name = "elasticsearch-config";
    paths = [
      (pkgs.writeTextDir "elasticsearch.yml" esConfig)
      (if es5 then (pkgs.writeTextDir "log4j2.properties" cfg.logging)
              else (pkgs.writeTextDir "logging.yml" cfg.logging))
    ];
    # Elasticsearch 5.x won't start when the scripts directory does not exist
    postBuild = if es5 then "${pkgs.coreutils}/bin/mkdir -p $out/scripts" else "";
  };

  esPlugins = pkgs.buildEnv {
    name = "elasticsearch-plugins";
    paths = cfg.plugins;
    # Elasticsearch 5.x won't start when the plugins directory does not exist
    postBuild = if es5 then "${pkgs.coreutils}/bin/mkdir -p $out/plugins" else "";
  };

in {

  ###### interface

  options.services.elasticsearch = {
    enable = mkOption {
      description = "Whether to enable elasticsearch.";
      default = false;
      type = types.bool;
    };

    package = mkOption {
      description = "Elasticsearch package to use.";
      default = pkgs.elasticsearch5;
      defaultText = "pkgs.elasticsearch5";
      type = types.package;
    };

    listenAddress = mkOption {
      description = "Elasticsearch listen address.";
      default = "127.0.0.1";
      type = types.str;
    };

    port = mkOption {
      description = "Elasticsearch port to listen for HTTP traffic.";
      default = 9200;
      type = types.int;
    };

    tcp_port = mkOption {
      description = "Elasticsearch port for the node to node communication.";
      default = 9300;
      type = types.int;
    };

    cluster_name = mkOption {
      description = "Elasticsearch name that identifies your cluster for auto-discovery.";
      default = "elasticsearch";
      type = types.str;
    };

    extraConf = mkOption {
      description = "Extra configuration for elasticsearch.";
      default = "";
      type = types.str;
      example = ''
        node.name: "elasticsearch"
        node.master: true
        node.data: false
      '';
    };

    logging = mkOption {
      description = "Elasticsearch logging configuration.";
      default =
        if es5 then ''
          logger.action.name = org.elasticsearch.action
          logger.action.level = info

          appender.console.type = Console
          appender.console.name = console
          appender.console.layout.type = PatternLayout
          appender.console.layout.pattern = [%d{ISO8601}][%-5p][%-25c{1.}] %marker%m%n

          rootLogger.level = info
          rootLogger.appenderRef.console.ref = console
        '' else ''
          rootLogger: INFO, console
          logger:
            action: INFO
            com.amazonaws: WARN
          appender:
            console:
              type: console
              layout:
                type: consolePattern
                conversionPattern: "[%d{ISO8601}][%-5p][%-25c] %m%n"
        '';
      type = types.str;
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/elasticsearch";
      description = ''
        Data directory for elasticsearch.
      '';
    };

    logsDir = mkOption {
      type = types.path;
      default = "/var/log/elasticsearch";
      description = ''
        Log directory for elasticsearch.
      '';
    };

    extraCmdLineOptions = mkOption {
      description = "Extra command line options for the elasticsearch launcher.";
      default = [];
      type = types.listOf types.str;
    };

    defaultJavaOptions = mkOption {
      description = "Default command line options for Java";
      default = [
        "-Des.path.logs=${cfg.logsDir}"
        "-Des.path.data=${cfg.dataDir}"
        "-Xss256k"
        "-Xmx2g"
      ];
      example = [
        "-Des.security.manager.enabled=false"
      ];
    };

    extraJavaOptions = mkOption {
      description = "Extra command line options for Java.";
      default = [];
      example = [
        "-XX:+UseCompressedOops"
        "-XX:+HeapDumpOnOutOfMemoryError"
        "-XX:+PrintFlagsFinal"
        "-Djava.net.preferIPv4Stack=true"
      ];
      type = types.listOf types.str;
    };

    plugins = mkOption {
      description = "Extra elasticsearch plugins";
      default = [];
      type = types.listOf types.package;
    };

  };

  ###### implementation

  config = mkIf cfg.enable {
    systemd.services.elasticsearch = {
      description = "Elasticsearch Daemon";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      path = [ pkgs.inetutils ];
      environment = {
        ES_PATH_CONF = confDir;
        ES_PLUGINS_DIR = esPlugins;
        ES_HOME = cfg.dataDir;
        ES_JAVA_OPTS = toString (cfg.defaultJavaOptions ++ cfg.extraJavaOptions);
        ES_JVM_OPTS = toString (cfg.defaultJavaOptions ++ cfg.extraJavaOptions);
      };
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/elasticsearch ${toString cfg.extraCmdLineOptions}";
        User = "elasticsearch";
        PermissionsStartOnly = true;
        LimitNOFILE = "1024000";
      };
      preStart = ''
        ${optionalString (!config.boot.isContainer) ''
          # Only set vm.max_map_count if lower than ES required minimum
          # This avoids conflict if configured via boot.kernel.sysctl
          if [ `${pkgs.procps}/bin/sysctl -n vm.max_map_count` -lt 262144 ]; then
            ${pkgs.procps}/bin/sysctl -w vm.max_map_count=262144
          fi
        ''}

        mkdir -m 0700 -p ${cfg.dataDir}
        mkdir -m 0700 -p ${cfg.logsDir}

        # Install plugins
        ln -sfT ${esPlugins}/plugins ${cfg.dataDir}/plugins
        ln -sfT ${cfg.package}/lib ${cfg.dataDir}/lib
        ln -sfT ${cfg.package}/modules ${cfg.dataDir}/modules
        ln -sfT ${cfg.package}/logs ${cfg.logsDir}
        if [ "$(id -u)" = 0 ]; then
          chown -R elasticsearch:elasticsearch "${cfg.dataDir}" "${cfg.logsDir}"
        fi

      '';
    };

    environment.systemPackages = [ cfg.package ];

    users = {
      groups.elasticsearch.gid = config.ids.gids.elasticsearch;
      users.elasticsearch = {
        uid = config.ids.uids.elasticsearch;
        description = "Elasticsearch daemon user";
        home = cfg.dataDir;
        group = "elasticsearch";
      };
    };
  };
}
