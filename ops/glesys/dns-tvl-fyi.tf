# DNS configuration for tvl.fyi

resource "glesys_dnsdomain" "tvl_fyi" {
  name = "tvl.fyi"
}

resource "glesys_dnsdomain_record" "tvl_fyi_NS1" {
  domain = glesys_dnsdomain.tvl_fyi.id
  host   = "@"
  type   = "NS"
  data   = "ns1.namesystem.se."
}

resource "glesys_dnsdomain_record" "tvl_fyi_NS2" {
  domain = glesys_dnsdomain.tvl_fyi.id
  host   = "@"
  type   = "NS"
  data   = "ns2.namesystem.se."
}

resource "glesys_dnsdomain_record" "tvl_fyi_NS3" {
  domain = glesys_dnsdomain.tvl_fyi.id
  host   = "@"
  type   = "NS"
  data   = "ns3.namesystem.se."
}

resource "glesys_dnsdomain_record" "tvl_fyi_apex_A" {
  domain = glesys_dnsdomain.tvl_fyi.id
  host   = "@"
  type   = "A"
  data   = var.whitby_ipv4
}

resource "glesys_dnsdomain_record" "tvl_fyi_apex_AAAA" {
  domain = glesys_dnsdomain.tvl_fyi.id
  host   = "@"
  type   = "AAAA"
  data   = var.whitby_ipv6
}

resource "glesys_dnsdomain_record" "tvl_fyi_whitby_A" {
  domain = glesys_dnsdomain.tvl_fyi.id
  host   = "whitby"
  type   = "A"
  data   = var.whitby_ipv4
}

resource "glesys_dnsdomain_record" "tvl_fyi_whitby_AAAA" {
  domain = glesys_dnsdomain.tvl_fyi.id
  host   = "whitby"
  type   = "AAAA"
  data   = var.whitby_ipv6
}

resource "glesys_dnsdomain_record" "tvl_fyi_nevsky_A" {
  domain = glesys_dnsdomain.tvl_fyi.id
  host   = "nevsky"
  type   = "A"
  data   = var.nevsky_ipv4
}

resource "glesys_dnsdomain_record" "tvl_fyi_nevsky_AAAA" {
  domain = glesys_dnsdomain.tvl_fyi.id
  host   = "nevsky"
  type   = "AAAA"
  data   = var.nevsky_ipv6
}

resource "glesys_dnsdomain_record" "tvl_fyi_bugry_A" {
  domain = glesys_dnsdomain.tvl_fyi.id
  host   = "bugry"
  type   = "A"
  data   = var.bugry_ipv4
}

resource "glesys_dnsdomain_record" "tvl_fyi_bugry_AAAA" {
  domain = glesys_dnsdomain.tvl_fyi.id
  host   = "bugry"
  type   = "AAAA"
  data   = var.bugry_ipv6
}

resource "glesys_dnsdomain_record" "tvl_fyi_nixery-01_A" {
  domain = glesys_dnsdomain.tvl_fyi.id
  host   = "nixery-01"
  type   = "A"
  data   = "51.250.51.78"
}

# Explicit records for all services running on whitby
resource "glesys_dnsdomain_record" "tvl_fyi_whitby_services" {
  domain   = glesys_dnsdomain.tvl_fyi.id
  type     = "CNAME"
  data     = "whitby.tvl.fyi."
  host     = each.key
  for_each = toset(local.whitby_services)
}

resource "glesys_dnsdomain_record" "tvl_fyi_net_CNAME" {
  domain = glesys_dnsdomain.tvl_fyi.id
  type   = "CNAME"
  data   = "sanduny.tvl.su."
  host   = "net"
}

# Google Domains mail forwarding configuration (no sending)
resource "glesys_dnsdomain_record" "tvl_fyi_MX_5" {
  domain = glesys_dnsdomain.tvl_fyi.id
  host   = "@"
  type   = "MX"
  data   = "5 gmr-smtp-in.l.google.com."
}

resource "glesys_dnsdomain_record" "tvl_fyi_MX_10" {
  domain = glesys_dnsdomain.tvl_fyi.id
  host   = "@"
  type   = "MX"
  data   = "10 alt1.gmr-smtp-in.l.google.com."
}

resource "glesys_dnsdomain_record" "tvl_fyi_MX_20" {
  domain = glesys_dnsdomain.tvl_fyi.id
  host   = "@"
  type   = "MX"
  data   = "20 alt2.gmr-smtp-in.l.google.com."
}

resource "glesys_dnsdomain_record" "tvl_fyi_MX_30" {
  domain = glesys_dnsdomain.tvl_fyi.id
  host   = "@"
  type   = "MX"
  data   = "30 alt3.aspmx.l.google.com."
}

resource "glesys_dnsdomain_record" "tvl_fyi_MX_40" {
  domain = glesys_dnsdomain.tvl_fyi.id
  host   = "@"
  type   = "MX"
  data   = "40 alt4.gmr-smtp-in.l.google.com."
}
