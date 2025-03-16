# Configure snix DNS resources.

terraform {
  required_providers {
    digitalocean = {
      source = "digitalocean/digitalocean"
    }
  }

  backend "s3" {
    endpoints = {
      s3 = "https://s3.dualstack.eu-central-1.amazonaws.com"
    }

    bucket = "snix-tfstate"
    key    = "terraform/snix-dns"
    region = "eu-central-1"

    skip_credentials_validation = true
    skip_metadata_api_check = true
    skip_requesting_account_id  = true
  }
}

variable "sni_proxy_ipv4" {
  type    = string
  default = "163.172.69.160"
}

variable "public01_ipv6" {
  type    = string
  default = "2a01:4f8:c013:3e62::1"
}

variable "public01_ipv4" {
  type    = string
  default = "49.13.70.233"
}

variable "gerrit01_ipv6" {
  type    = string
  default = "2a01:4f8:c17:6188::1"
}

variable "gerrit01_ipv4" {
  type    = string
  default = "138.199.144.184"
}

variable "build01_ipv6" {
  type    = string
  default = "2001:bc8:38ee:100:7000::20"
}

variable "meta01_ipv4" {
  type    = string
  default = "142.132.184.228"
}

variable "meta01_ipv6" {
  type    = string
  default = "2a01:4f8:c013:4a58::1"
}

locals {
  public01_services = [
    "auth",
    "bolt",
    "git",
    "status"
  ]

  gerrit01_services = [
    "cl"
  ]

  meta01_services = [
    "mimir",
    "loki",
    "tempo"
  ]
}
