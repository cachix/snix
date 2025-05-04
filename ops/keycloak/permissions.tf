# This sets the permissions for various groups and users.

# TODO: Realm-level composite roles
# resource "keycloak_role" "is_local_admin" {
#   composite_roles = [
#     keycloak_role.blablabla.id
#   ]
# }
#
# resource "keycloak_role" "can_manage_trusted_contributors" {
# }
#
# # WARNING: This give PII access to the user.
# resource "keycloak_role" "can_manage_snix" {
# }

# Realm-level groups to bestow to users.
resource "keycloak_group" "snix_core_team" {
  realm_id    = keycloak_realm.snix.id
  name        = "snix core team"
}

resource "keycloak_group_roles" "snix_core_team_roles" {
  realm_id    = keycloak_realm.snix.id
  group_id    = keycloak_group.snix_core_team.id

  role_ids = [
    # keycloak_role.is_local_admin,
    # keycloak_role.can_manage_snix,
    keycloak_role.grafana_admin.id,
    # keycloak_role.forgejo_admin.id,
    # keycloak_role.gerrit_admin.id
  ]
}

resource "keycloak_group_memberships" "snix_core_team_members" {
  realm_id    = keycloak_realm.snix.id
  group_id    = keycloak_group.snix_core_team.id

  members = [
    "edef",
    "flokli",
    "raitobezarius"
  ]
}

resource "keycloak_group" "trusted_contributors" {
  name        = "trusted contributors"
  realm_id    = keycloak_realm.snix.id

}

resource "keycloak_group_roles" "trusted_contributors_roles" {
  realm_id    = keycloak_realm.snix.id
  group_id    = keycloak_group.trusted_contributors.id

  role_ids = [
    keycloak_role.grafana_editor.id
  ]
}
