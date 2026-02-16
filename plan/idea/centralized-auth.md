# Centralized Authentication (LDAP + OIDC)

## Problem

Each application manages its own users independently. Adding a new user
means creating accounts in PocketBase, PostgreSQL, and any future services
separately. No single sign-on — users authenticate into each app
individually. As the number of self-hosted apps grows, this becomes
tedious for both admin and users.

## Proposal

Run a centralized authentication stack so users are defined once and can
log into all apps from a single place. Two protocols cover most apps:

- **LDAP** — centralized user directory. Apps query it to verify
  credentials. One password for everything, but users still see a login
  form per app (no SSO).
- **OIDC** (OpenID Connect) — centralized login flow. Apps redirect
  users to a single login page. After authenticating once, other apps
  recognize the session (SSO).

These are complementary. LDAP provides the user directory, OIDC provides
the login experience. Apps connect via whichever protocol they support.

## Options

### User Directory (LDAP)

- **LLDAP** — lightweight LDAP server designed for homelabs. Simple web UI
  for user/group management. Minimal resource usage. Packaged in nixpkgs
  (`services.lldap`). Does not implement the full LDAP spec, but covers
  what self-hosted apps need.
- **OpenLDAP** — full-featured LDAP server. More powerful but significantly
  more complex to configure. Overkill for a homelab with a handful of users.

### OIDC / SSO Provider

- **Authelia** — lightweight auth server. Provides OIDC, 2FA, and access
  control policies. Pairs well with LLDAP as its user backend. Packaged in
  nixpkgs (`services.authelia`). Popular in the homelab community.
- **Keycloak** — enterprise-grade identity provider. Bundles its own user
  store plus OIDC/SAML/LDAP. Very powerful but heavy (Java, needs
  PostgreSQL). More than a homelab typically needs.
- **Kanidm** — Rust-based identity server that combines directory + OIDC
  in one binary. Newer, less ecosystem support, but clean design. Packaged
  in nixpkgs.

## Recommended Stack

**LLDAP + Authelia** — lightweight, well-supported, and covers both
protocols:

1. **LLDAP** — user directory. Admin creates users and groups here.
2. **Authelia** — OIDC provider. Uses LLDAP as its backend. Handles SSO
   and optional 2FA.
3. Apps that support OIDC authenticate through Authelia (with SSO).
4. Apps that only support LDAP query LLDAP directly (same credentials,
   no SSO).

## Where to Host

Both LLDAP and Authelia are lightweight and could run on builder. If auth
becomes critical infrastructure, a dedicated VM or running on the always-on
machine makes sense.

## Scope

A minimal setup would cover:
- LLDAP running with admin + one regular user
- Authelia configured as OIDC provider backed by LLDAP
- One app wired up to OIDC as proof of concept (e.g., Grafana)
- One app wired up to LDAP as proof of concept

## Decision

Not yet. Revisit when more self-hosted apps are added and managing
separate user accounts becomes a real pain point. Current app count
(PocketBase, PostgreSQL) is low enough that per-app accounts are fine.
