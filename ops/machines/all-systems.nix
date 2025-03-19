{ depot, ... }:

(with depot.ops.machines; [
  # Archivist EC2 machine
  archivist-ec2
  # Gerrit instance
  gerrit01
  # Public-facing services
  public01
  # Build machine
  build01
  # Observability stack and internal software
  meta01
  # fetch-through cache for cache.nixos.org
  snix-cache
])
