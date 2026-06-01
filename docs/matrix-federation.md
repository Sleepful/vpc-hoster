# Matrix Federation Strategy

The homeserver currently runs with federation disabled — a private island for
homelab users, protected from external spam and unsolicited contacts.

## Current state

- Federation listener removed from Synapse (`synapse.nix`)
- `federation_domain_whitelist = []` as defense-in-depth
- `.well-known/matrix/server` endpoint removed from nginx (`web.nix`)
- All rooms are private, invite-only
- OIDC via Keycloak (`password-less` realm, `matrix-users` group gate)

## Future: dual-instance federation

When federation becomes desirable (exploring the Matrix fediverse, joining
public rooms, bridging), add a **second Synapse instance** — not a replacement.

### Architecture

```
Private instance (today)          Federated instance (future)
├── federation: off                ├── federation: on
├── all current users              ├── new MXID for curious users
├── password-less realm OIDC       ├── same Keycloak realm (or separate)
├── hermes bot                     ├── new hermes bot (optional)
└── DB: matrix-synapse             └── DB: matrix-synapse-fed
```

### Implementation sketch

1. **Second Postgres database:** `matrix-synapse-fed` with its own
   `matrix-synapse` role (or a new one)
2. **Second listener:** Synapse on `::1:8009` (loopback), nginx vhost at
   `fed.jose.cloud` or similar, with `.well-known/matrix/server` pointing to it
3. **Keycloak:** same realm works. Users who want federation create a separate
   MXID (e.g., `@alice:fed.jose.cloud`). The `@hermes` bot stays on the
   private instance
4. **Client:** FluffyChat supports multi-account natively. Log into both
   servers in one app

### No Docker required

Pure NixOS — two Synapse module blocks with separate settings, databases, and
nginx virtualHosts. See `machines/house/src/service/synapse.nix` for the
current single-instance template.

## Reverting to single-instance federation

If federation is ever wanted on the CURRENT instance (not a second one):

1. `synapse.nix`: add `"federation"` back to listener resources
2. `synapse.nix`: set `federation_domain_whitelist` to the desired domain(s),
   or remove it entirely to allow all
3. `web.nix`: restore `.well-known/matrix/server` endpoint pointing to
   `matrix.jose.cloud:443`

The changes are small and reversible — no data migration, no user impact.
