resource "keycloak_openid_client" "grafana" {
  realm_id              = keycloak_realm.snix.id
  client_id             = "grafana"
  name                  = "Grafana"
  enabled               = true
  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  base_url              = "https://status.snix.dev"

  // disable full scope, roles are assigned via keycloak_openid_user_client_role_protocol_mapper
  full_scope_allowed    = false

  valid_redirect_uris = [
    "https://status.snix.dev/*",
  ]
}

resource "keycloak_role" "grafana_editor" {
  realm_id    = keycloak_realm.snix.id
  client_id   = keycloak_openid_client.grafana.id
  name        = "Editor"
  description = "Can edit things in Grafana"
}

resource "keycloak_role" "grafana_admin" {
  realm_id    = keycloak_realm.snix.id
  client_id   = keycloak_openid_client.grafana.id
  name        = "Admin"
  description = "Can admin things in Grafana"
}

# Expose the above two roles at `grafana_roles`
resource "keycloak_openid_user_client_role_protocol_mapper" "grafana_role_mapper" {
  realm_id = keycloak_realm.snix.id
  client_id = keycloak_openid_client.grafana.id
  name = "grafana_roles mapper"

  claim_name = "grafana_roles"
  claim_value_type = "String"
  add_to_id_token = true
  add_to_access_token = true
  multivalued = true

  # https://github.com/keycloak/terraform-provider-keycloak/issues/1016
  client_id_for_role_mappings = keycloak_openid_client.grafana.client_id
}

# It seems this is necessary
resource "keycloak_openid_client_default_scopes" "grafana_default_scopes" {
  realm_id  = keycloak_realm.snix.id
  client_id = keycloak_openid_client.grafana.id

  default_scopes = [
    "profile",
    "email",
    "roles",
  ]
}
