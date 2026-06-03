# Keycloak Group Gating: Matrix & Discourse

TL;DR process for creating groups, clients, and gating access so only
specific Keycloak users can authenticate to specific services.

## Terminology

- **Group:** a Keycloak collection of users (e.g., `matrix-users`)
- **Client:** a Keycloak application entry (e.g., `synapse`, `discourse`)
- **Client Scope:** the set of claims (data) injected into a token for a
  specific client. Scopes are applied to clients, not to users.
- **Group Membership mapper:** a mapper on a client scope that injects the
  user's group names into the OIDC token's `groups` claim.
- **attribute_requirements:** a Synapse config directive that checks for a
  specific value in a token claim and rejects authentication if absent.
- **Authorization:** Keycloak's optional per-client access control layer
  (policies + permissions) that gates authentication BEFORE the token is
  issued. Used when the service itself has no group-gate config.

## Matrix Gating (already configured)

### Keycloak side

1. **Create group:** `matrix-users`
2. **Assign Group Membership mapper:** Clients → `synapse` → Client Scopes →
   `synapse-dedicated` → Add mapper → "Group Membership"
   - Token Claim Name: `groups`
   - Full group path: OFF
3. **Add users** to the `matrix-users` group

### Synapse side (Nix, `synapse-extra` sops template)

```yaml
oidc_providers:
  - idp_id: keycloak
    # ...
    attribute_requirements:
      - attribute: groups
        value: matrix-users
```

### How it works

1. User authenticates via `synapse` client
2. Keycloak injects `"groups": ["matrix-users", ...]` into the token
3. Synapse checks: does `token.groups` contain `matrix-users`?
4. If yes → account created/linked, auth proceeds
5. If no → authentication rejected at Synapse

## Discourse Gating (Authorization pattern)

Discourse's OIDC plugin has no Nix-configurable `attribute_requirements` like
Synapse. The gate is enforced at the Keycloak level instead.

### Keycloak side

1. **Create group:** `discourse-users`
2. **Ensure Group Membership mapper exists** on the `discourse` client scope
   (same setup as Matrix — only needed if Discourse itself consumes the
   `groups` claim)
3. **Enable Authorization:** Clients → `discourse` → Authorization → Enable
4. **Create policy:** Authorization → Policies → Create → Group →
   select `discourse-users` → Save
5. **Create permission:** Authorization → Permissions → Create resource-based
   - Resources: "Default Resource"
   - Policies: pick your group policy
   - Decision Strategy: "Affirmative"
   - Save
6. **Add users** to the `discourse-users` group

### How it works

1. User authenticates via `discourse` client
2. Keycloak evaluates Authorization: is user in `discourse-users` group?
3. If yes → token issued, Discourse receives the user
4. If no → Keycloak returns "access denied," Discourse never sees the user

## Adding a new service with group gating

| Step | Where | Notes |
|------|-------|-------|
| 1. Create Keycloak group | Groups → New | e.g., `grafana-users` |
| 2. Add Group Membership mapper | Client → Client Scopes → Dedicated scope → Mappers | Use same `groups` claim name |
| 3. Add users to group | Groups → select group → Members | |
| 4. Gate access | Two paths: | |
| 4a. Authorization (Keycloak-level) | Client → Authorization → Enable, Policy, Permission | Use when service has no `attribute_requirements` |
| 4b. attribute_requirements (service-level) | Service config / Nix module | Use when service supports claim-based gating (like Synapse) |

## Debugging

- **"access denied" at Keycloak:** user not in required group. Check
  Authorization → Evaluate tab, enter the user, see which permissions fail.
- **Service rejects user:** check the `groups` claim is present in the token.
  Keycloak → Client Scopes → Evaluate → enter user → Generated Access Token
  → look for `groups` in the payload.
- **Admin still works:** Keycloak admin users in the master realm are
  unaffected by client-level authorization policies.
