{ depot
, pkgs
, ...
}:

let
  clickhouseConfigAWS = builtins.toFile "clickhouse-local.xml" ''
    <clickhouse>
        <s3>
          <use_environment_credentials>true</use_environment_credentials>
        </s3>
    </clickhouse>
  '';
  # clickhouse has a very odd AWS config concept.
  # Configure it to be a bit more sane.
  clickhouseLocalFixedAWS = pkgs.runCommand "clickhouse-local-fixed"
    {
      nativeBuildInputs = [ pkgs.makeWrapper ];
    } ''
    mkdir -p $out/bin
    makeWrapper ${pkgs.clickhouse}/bin/clickhouse-local $out/bin/clickhouse-local \
      --append-flags "-C ${clickhouseConfigAWS}"
  '';

in
depot.nix.readTree.drvTargets {
  inherit clickhouseLocalFixedAWS;

  parse-bucket-logs = pkgs.runCommand "archivist-parse-bucket-logs"
    {
      nativeBuildInputs = [ pkgs.makeWrapper ];
    } ''
    mkdir -p $out/bin
    makeWrapper ${(pkgs.writers.writeRust "parse-bucket-logs-unwrapped" {} ./parse_bucket_logs.rs)} $out/bin/archivist-parse-bucket-logs \
      --prefix PATH : ${pkgs.lib.makeBinPath [ clickhouseLocalFixedAWS ]}
  '';


  # A shell, by default pointing us to the archivist SSO profile / account by default.
  shell = pkgs.mkShell {
    name = "archivist-shell";
    packages = with pkgs; [ awscli2 ];

    AWS_PROFILE = "archivist";
    AWS_CONFIG_FILE = pkgs.writeText "aws-config" ''
      [sso-session nixos]
      sso_region = eu-north-1
      sso_start_url = https://nixos.awsapps.com/start
      sso_registration_scopes = sso:account:access

      [profile "archeologist"]
      sso_session = nixos
      sso_account_id = 080433136561 # nixos root
      sso_role_name = archeologist

      [profile "archivist"]
      sso_session = nixos
      sso_account_id = 286553126452 # archivist
      sso_role_name = AWSAdministratorAccess
    '';
  };
}
