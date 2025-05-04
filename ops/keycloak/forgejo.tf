resource "keycloak_openid_client" "forgejo" {
  realm_id                                 = keycloak_realm.snix.id
  client_id                                = "forgejo"
  name                                     = "snix Forgejo"
  enabled                                  = true
  access_type                              = "CONFIDENTIAL"
  standard_flow_enabled                    = true
  base_url                                 = "https://git.snix.dev"

  description                              = "snix project's code browsing, search and issue tracker"
  direct_access_grants_enabled             = true
  exclude_session_state_from_auth_response = false

  valid_redirect_uris = [
    "https://git.snix.dev/*",
  ]

  web_origins = [
    "https://git.snix.dev",
  ]
}

# resource "keycloak_role" "forgejo_admin" {
# }
#
# resource "keycloak_role" "forgejo_trusted_contributor" {
# }
