# On the Buildkite site, first create manually, then use
# $BUILDKITE_URL/realms/$realm/protocol/saml/descriptor as Meta Data URL
resource "keycloak_saml_client" "buildkite" {
  realm_id  = keycloak_realm.snix.id
  client_id = "https://buildkite.com"
  name      = "Buildkite"
  base_url  = "https://buildkite.com/sso/snix"

  client_signature_required   = false
  assertion_consumer_post_url = "https://buildkite.com/sso/~/01969dae-b653-4e3e-8056-eff685823c6f/saml/consume"

  valid_redirect_uris = [
    "https://buildkite.com/sso/~/01969dae-b653-4e3e-8056-eff685823c6f/saml/consume"
  ]

  full_scope_allowed = false
}

resource "keycloak_saml_user_attribute_protocol_mapper" "buildkite_email" {
  realm_id                   = keycloak_realm.snix.id
  client_id                  = keycloak_saml_client.buildkite.id
  name                       = "buildkite-email-mapper"
  user_attribute             = "email"
  saml_attribute_name        = "email"
  saml_attribute_name_format = "Unspecified"
}

resource "keycloak_saml_user_attribute_protocol_mapper" "buildkite_name" {
  realm_id                   = keycloak_realm.snix.id
  client_id                  = keycloak_saml_client.buildkite.id
  name                       = "buildkite-name-mapper"
  user_attribute             = "displayName"
  saml_attribute_name        = "name"
  saml_attribute_name_format = "Unspecified"
}
