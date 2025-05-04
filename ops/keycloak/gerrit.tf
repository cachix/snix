resource "keycloak_openid_client" "gerrit" {
  realm_id                                 = keycloak_realm.snix.id
  client_id                                = "gerrit"
  name                                     = "snix Gerrit"
  enabled                                  = true
  access_type                              = "CONFIDENTIAL"
  standard_flow_enabled                    = true
  base_url                                 = "https://cl.snix.dev"
  description                              = "snix project's code review tool"
  direct_access_grants_enabled             = true
  exclude_session_state_from_auth_response = false

  valid_redirect_uris = [
    "https://cl.snix.dev/*",
  ]

  web_origins = [
    "https://cl.snix.dev",
  ]
}

# resource "keycloak_role" "gerrit_admin" {
# }
#
# resource "keycloak_role" "gerrit_trusted_contributor" {
# }
