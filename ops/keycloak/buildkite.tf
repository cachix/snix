# resource "keycloak_saml_client" "buildkite" {
#   realm_id  = keycloak_realm.snix.id
#   client_id = "https://buildkite.com"
#   name      = "Buildkite"
#   base_url  = "https://buildkite.com/sso/snix"

#   client_signature_required   = false
#   assertion_consumer_post_url = "https://buildkite.com/sso/~/1531aca5-f49c-4151-8832-a451e758af4c/saml/consume"

#   valid_redirect_uris = [
#     "https://buildkite.com/sso/~/1531aca5-f49c-4151-8832-a451e758af4c/saml/consume"
#   ]
# }

# resource "keycloak_saml_user_attribute_protocol_mapper" "buildkite_email" {
#   realm_id                   = keycloak_realm.snix.id
#   client_id                  = keycloak_saml_client.buildkite.id
#   name                       = "buildkite-email-mapper"
#   user_attribute             = "email"
#   saml_attribute_name        = "email"
#   saml_attribute_name_format = "Unspecified"
# }

# resource "keycloak_saml_user_attribute_protocol_mapper" "buildkite_name" {
#   realm_id                   = keycloak_realm.snix.id
#   client_id                  = keycloak_saml_client.buildkite.id
#   name                       = "buildkite-name-mapper"
#   user_attribute             = "displayName"
#   saml_attribute_name        = "name"
#   saml_attribute_name_format = "Unspecified"
# }
