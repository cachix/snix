variable "bornhack_client_secret" {
  type = string
}

variable "github_client_secret" {
  type = string
}

variable "gitlab_client_secret" {
  type = string
}

resource "keycloak_oidc_identity_provider" "github" {
  alias                 = "github"
  provider_id           = "github"
  client_id             = "Ov23liKpXqs0aPaVgDpg"
  client_secret         = var.github_client_secret
  realm                 = keycloak_realm.snix.id
  backchannel_supported = false
  gui_order             = "1"
  store_token           = false
  sync_mode             = "IMPORT"
  trust_email           = true
  default_scopes        = "openid user:email"

  authorization_url = ""
  token_url         = ""
}

resource "keycloak_oidc_identity_provider" "gitlab" {
  alias                 = "gitlab"
  provider_id           = "gitlab"
  client_id             = "aa15f85b418bde7549216c8d4ecf23849f667a9be496eebaed4b9cbafe17a176"
  client_secret         = var.gitlab_client_secret
  realm                 = keycloak_realm.snix.id
  backchannel_supported = false
  gui_order             = "2"
  store_token           = false
  sync_mode             = "IMPORT"
  trust_email           = true
  default_scopes        = "openid read_user"

  authorization_url = ""
  token_url         = ""
}

resource "keycloak_oidc_identity_provider" "bornhack" {
  alias                 = "bornhack"
  provider_id           = "oidc"
  client_id             = "I9RQMXbukxjUAgtYaKeGTqJL3pPoRTw34tZ6jita"
  client_secret         = var.bornhack_client_secret
  realm                 = keycloak_realm.snix.id
  backchannel_supported = false
  gui_order             = "3"
  store_token           = false
  sync_mode             = "IMPORT"
  trust_email           = true
  default_scopes        = "openid profile email"

  authorization_url = "https://bornhack.dk/o/authorize/"
  token_url         = "https://bornhack.dk/o/token/"
  validate_signature = true
  user_info_url = "https://bornhack.dk/o/userinfo/"
  jwks_url = "https://bornhack.dk/o/.well-known/jwks.json"
  issuer = "https://bornhack.dk/o"

  extra_config = {
    pkceEnabled = true
    pkceMethod = "S256"
  }
}

# Bornhack uses a uuid as `sub`, and has an additional `nickname` claim, which we use.
# Normally, we'd simply import this as the username, but for now we cannot, due to
# https://github.com/bornhack/bornhack-website/issues/1837
# resource "keycloak_custom_identity_provider_mapper" "bornhack_nickname" {
#   realm = keycloak_realm.snix.id
#   name = "bornhack_nickname"
#   identity_provider_alias = keycloak_oidc_identity_provider.bornhack.alias
#   identity_provider_mapper = "oidc-user-attribute-idp-mapper"

#   extra_config = {
#     syncMode = "INHERIT"
#     claim = "nickname"
#     "user.attribute" = "username"
#   }
# }
