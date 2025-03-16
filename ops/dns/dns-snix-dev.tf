# DNS configuration for snix.dev

resource "digitalocean_domain" "snix_dev" {
  name = "snix.dev"
}

# Infrastructure records

resource "digitalocean_record" "snix_dev_infra_gerrit01" {
  domain   = digitalocean_domain.snix_dev.id
  type     = "AAAA"
  name     = "gerrit01.infra"
  value    = var.gerrit01_ipv6
}

resource "digitalocean_record" "snix_dev_infra_public01" {
  domain   = digitalocean_domain.snix_dev.id
  type     = "AAAA"
  name     = "public01.infra"
  value    = var.public01_ipv6
}

resource "digitalocean_record" "snix_dev_infra_build01" {
  domain   = digitalocean_domain.snix_dev.id
  type     = "AAAA"
  name     = "build01.infra"
  value    = var.build01_ipv6
}

resource "digitalocean_record" "snix_dev_infra_meta01_v4" {
  domain   = digitalocean_domain.snix_dev.id
  type     = "A"
  name     = "meta01.infra"
  value    = var.meta01_ipv4
}

resource "digitalocean_record" "snix_dev_infra_meta01_v6" {
  domain   = digitalocean_domain.snix_dev.id
  type     = "AAAA"
  name     = "meta01.infra"
  value    = var.meta01_ipv6
}

resource "digitalocean_record" "snix_dev_infra_gerrit01_v4" {
  domain   = digitalocean_domain.snix_dev.id
  type     = "A"
  name     = "gerrit01.infra"
  value    = var.gerrit01_ipv4
}

resource "digitalocean_record" "snix_dev_infra_gerrit01_v6" {
  domain   = digitalocean_domain.snix_dev.id
  type     = "AAAA"
  name     = "gerrit01.infra"
  value    = var.gerrit01_ipv6
}

resource "digitalocean_record" "snix_dev_infra_public01_v4" {
  domain   = digitalocean_domain.snix_dev.id
  type     = "A"
  name     = "public01.infra"
  value    = var.public01_ipv4
}

resource "digitalocean_record" "snix_dev_infra_public01_v6" {
  domain   = digitalocean_domain.snix_dev.id
  type     = "AAAA"
  name     = "public01.infra"
  value    = var.public01_ipv6
}

# Email records
resource "digitalocean_record" "snix_dev_mail_v4" {
  domain  = digitalocean_domain.snix_dev.id
  type    = "A"
  value   = "49.12.112.149"
  name    = "mail"
}

resource "digitalocean_record" "snix_dev_mail_v6" {
  domain  = digitalocean_domain.snix_dev.id
  type    = "AAAA"
  value   = "2a01:4f8:c013:3e62::2"
  name    = "mail"
}

# Explicit records for all services running on public01
resource "digitalocean_record" "snix_dev_public01" {
  domain   = digitalocean_domain.snix_dev.id
  type     = "CNAME"
  value    = "public01.infra.snix.dev."
  name     = each.key
  for_each = toset(local.public01_services)
}

# A snix.dev pointing to public01
resource "digitalocean_record" "snix_dev_public01_apex_a" {
  domain   = digitalocean_domain.snix_dev.id
  type     = "A"
  value    = var.public01_ipv4
  name     = "@"
}
# AAAA for snix.dev pointing to public01
resource "digitalocean_record" "snix_dev_public01_apex_aaaa" {
  domain   = digitalocean_domain.snix_dev.id
  type     = "AAAA"
  value    = var.public01_ipv6
  name     = "@"
}

# Explicit records for all services running on gerrit01
resource "digitalocean_record" "snix_dev_gerrit01" {
  domain   = digitalocean_domain.snix_dev.id
  type     = "CNAME"
  value    = "gerrit01.infra.snix.dev."
  name     = each.key
  for_each = toset(local.gerrit01_services)
}

# Explicit records for all services running on gerrit01
resource "digitalocean_record" "snix_dev_meta01" {
  domain   = digitalocean_domain.snix_dev.id
  type     = "CNAME"
  value    = "meta01.infra.snix.dev."
  name     = each.key
  for_each = toset(local.meta01_services)
}
