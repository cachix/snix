{ depot, pkgs, ... }: # readTree options
{ modulesPath, ... }: # passed by module system

let
  mod = name: depot.path.origSrc + ("/ops/modules/" + name);
in
{
  imports = [
    "${modulesPath}/virtualisation/amazon-image.nix"
    (mod "archivist.nix")
  ];

  nixpkgs.hostPlatform = "x86_64-linux";

  systemd.timers.parse-bucket-logs = {
    wantedBy = [ "multi-user.target" ];
    timerConfig.OnCalendar = "*-*-* 03:00:00 UTC";
  };

  systemd.services.parse-bucket-logs = {
    path = [ depot.contrib.archivist.parse-bucket-logs ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = (pkgs.writers.writePython3 "parse-bucket-logs-continuously"
        {
          libraries = [ pkgs.python3Packages.boto3 ];
        } ./parse-bucket-logs-continuously.py);
      DynamicUser = "yes";
      StateDirectory = "parse-bucket-logs";
    };
  };

  environment.systemPackages = [
    depot.contrib.archivist.parse-bucket-logs
  ];

  networking.hostName = "archivist-ec2";

  system.stateVersion = "23.05"; # Did you read the comment?
}

