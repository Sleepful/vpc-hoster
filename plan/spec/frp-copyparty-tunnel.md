# FRP Tunnel: Public Copyparty Access via House

## Summary

Expose builder's Copyparty instance to the public internet through an FRP
tunnel via house. The tunnel is off by default and toggled on/off with
justfile recipes. This enables sharing files with people outside Tailscale
via a public URL with password-protected access.

## Architecture

```
Internet user
  |
  | https://files.<domain>
  v
+----------------------------+        +---------------------------+
|  house (Hetzner VPS)       |        |  builder (home LAN)       |
|                            |        |                           |
|  nginx                     |        |  FRP client (frpc)        |
|   +- files.<domain>:443    |        |   +- connects to house:7000|
|   +- TLS termination       |        |   +- registers HTTP proxy |
|   +- proxy -> :8888        |        |   +- forwards to :3923    |
|                            |        |                           |
|  FRP server (frps)         |        |  Copyparty                |
|   +- control port 7000     |  <-->  |   +- port 3923            |
|   +- vhost HTTP port 8888  |        |   +- password-protected   |
|   +- token auth            |        |   +- serves /media        |
+----------------------------+        +---------------------------+
```

Traffic flow:
  browser -> house nginx (TLS) -> frps :8888 -> frpc on builder -> Copyparty :3923

FRP vhost routing: frps routes by HTTP Host header. Both tunnel.<domain>
and files.<domain> nginx vhosts proxy to the same frps port (8888), but
frps forwards each to the FRP client proxy that registered that domain.
This means tunnel.<domain> and files.<domain> can serve completely different
backends simultaneously.

## Security Model

1. **HTTPS**: nginx on house terminates TLS with a valid ACME certificate.
2. **FRP auth token**: Both frps (house) and frpc (builder) share a token
   stored in SOPS. Prevents unauthorized FRP clients from registering proxies.
3. **Copyparty auth**: Username/password required to access any content.
4. **Off by default**: The FRP client service on builder has no `wantedBy`,
   so it doesn't start on boot. Toggled manually via `just share-on` /
   `just share-off`. When off, `files.<domain>` returns a 502.

## Resolved Decisions

- Subdomain: `files` (configurable via identifiers)
- FRP auth: token-based, stored in SOPS on both machines
- FRP config format: migrate house server to new camelCase/instances pattern
- Nginx: separate vhost for `files.<domain>` (not merged with `tunnel`)
- FRP client: separate systemd service on builder, off by default

## Files Created (1 new)

| File                                        | Machine | Purpose                              |
|---------------------------------------------|---------|--------------------------------------|
| machines/builder/src/service/frp.nix        | builder | FRP client with Copyparty HTTP proxy |

## Files Modified (8 existing)

| File                                        | Change                                            |
|---------------------------------------------|---------------------------------------------------|
| machines/house/src/service/frp.nix          | Migrate to new config format + add auth token     |
| machines/house/src/service/web.nix          | Add `files` subdomain to ACME + nginx vhost       |
| machines/house/src/service/secrets.nix      | Add `frp_auth_token` secret + frp_env template    |
| machines/builder/src/service/secrets.nix    | Add `frp_auth_token` secret + frp_env template    |
| machines/builder/src/config.nix             | Add frp.nix import                                |
| shared/options/identifiers.nix              | Add `files` subdomain option                      |
| shared/identifiers/default.nix              | Add `files` subdomain default                     |
| justfile                                    | Add `share-on` and `share-off` recipes            |

## Implementation Details

### 1. Identifiers

Add `files` subdomain option:
- shared/options/identifiers.nix: `files = mkOption { type = types.str; default = "files"; };`
- shared/identifiers/default.nix: `files = lib.mkDefault "files";`
- private/identifiers/default.nix: `files = "files";` (or custom value)

### 2. SOPS Secrets

Both machines need an `frp_auth_token` secret.

Builder secrets.nix — add:
```nix
sops.secrets.frp_auth_token = {};

sops.templates.frp_env = {
  content = ''
    FRP_AUTH_TOKEN=${config.sops.placeholder.frp_auth_token}
  '';
  mode = "0440";
};
```

House secrets.nix — add:
```nix
sops.secrets.frp_auth_token = {};

sops.templates.frp_env = {
  content = ''
    FRP_AUTH_TOKEN=${config.sops.placeholder.frp_auth_token}
  '';
  mode = "0440";
};
```

Both SOPS secret files need the `frp_auth_token` value added:
- `just secret secrets/builder/core.yaml` — add `frp_auth_token: <token>`
- `just secret secrets/house/core.yaml` — add `frp_auth_token: <token>`

The token should be a random string (e.g. `openssl rand -hex 32`).
The same token must be used on both machines.

### 3. House FRP Server (migrate + auth)

Rewrite machines/house/src/service/frp.nix. Migrate from old format
(`settings.common` with `bind_port`/`vhost_http_port`) to new camelCase
format with auth:

```nix
{ config, ... }:
let
  ids = config.homelab.identifiers;
  rootDomain = ids.domain.root;
  sub = ids.subdomains;
  fqdn = name: "${name}.${rootDomain}";
in
{
  services.frp.enable = true;
  services.frp.role = "server";
  services.frp.settings = {
    bindPort = 7000;
    vhostHTTPPort = 8888;
    auth = {
      method = "token";
      token = "{{ .Envs.FRP_AUTH_TOKEN }}";
    };
  };
  services.frp.environmentFiles = [
    config.sops.templates.frp_env.path
  ];

  services.nginx.virtualHosts."${fqdn sub.tunnel}" = {
    onlySSL = true;
    useACMEHost = rootDomain;
    locations."/" = {
      proxyPass = "http://localhost:8888";
      proxyWebsockets = true;
    };
  };
}
```

Note: The old flat `services.frp.enable`/`.role`/`.settings` pattern is
remapped internally to `services.frp.instances.""`. Check if
`environmentFiles` is available at the flat level or only on instances.
If it requires the instances pattern, use:
```nix
services.frp.instances.default = {
  enable = true;
  role = "server";
  environmentFiles = [ ... ];
  settings = { ... };
};
```
In that case the systemd service name changes to `frp-default.service`.

### 4. Builder FRP Client (new file)

Create machines/builder/src/service/frp.nix:

```nix
{ config, lib, ... }:
let
  ids = config.homelab.identifiers;
  rootDomain = ids.domain.root;
  sub = ids.subdomains;
  fqdn = name: "${name}.${rootDomain}";
in
{
  services.frp.enable = true;
  services.frp.role = "client";
  services.frp.settings = {
    serverAddr = ids.hosts.house.ipv4;
    serverPort = 7000;
    auth = {
      method = "token";
      token = "{{ .Envs.FRP_AUTH_TOKEN }}";
    };
    proxies = [
      {
        name = "copyparty";
        type = "http";
        localIP = "127.0.0.1";
        localPort = 3923;
        customDomains = [ (fqdn sub.files) ];
      }
    ];
  };
  services.frp.environmentFiles = [
    config.sops.templates.frp_env.path
  ];

  # Do not start on boot — toggled manually via `just share-on/off`
  systemd.services.frp.wantedBy = lib.mkForce [];
}
```

Same note about instances pattern — if required, service name becomes
`frp-default.service` and justfile recipes must match.

### 5. House Nginx Vhost for files

In machines/house/src/service/web.nix:

Add `sub.files` to the extraDomainNames list for ACME:
```nix
extraDomainNames = map fqdn [
  ...
  sub.files
  sub.torrent
  sub.tunnel
];
```

Add a new virtualHost:
```nix
"${fqdn sub.files}" = {
  onlySSL = true;
  useACMEHost = rootDomain;
  locations."/" = {
    proxyPass = "http://localhost:8888";
    proxyWebsockets = true;
  };
};
```

### 6. Builder config.nix

Add `./service/frp.nix` to the imports list.

### 7. Justfile Recipes

```just
# Toggle public file sharing (FRP tunnel for Copyparty)
share-on:
	ssh {{NAME}} "systemctl start frp"

share-off:
	ssh {{NAME}} "systemctl stop frp"

share-status:
	ssh {{NAME}} "systemctl is-active frp || true"
```

Adjust service name if using the instances pattern (e.g. `frp-default`).

## Implementation Phases

### Phase 1: Infrastructure

1. Add `files` subdomain to identifiers (options + defaults + private)
2. Add `frp_auth_token` to SOPS secrets on both machines
3. Add FRP env templates to both secrets.nix files

### Phase 2: House Changes

4. Rewrite house frp.nix — migrate to new format + add auth
5. Add `files` nginx vhost + ACME entry in web.nix

### Phase 3: Builder Changes

6. Create builder frp.nix — FRP client, off by default
7. Add frp.nix import to builder config.nix

### Phase 4: Justfile

8. Add share-on, share-off, share-status recipes

### Phase 5: Verification

9. `just syntax`
10. `just check` (builder)
11. `just check house` or `just check-local house`

## Manual Steps Required

| Step                     | When               | How                                           |
|--------------------------|--------------------|-----------------------------------------------|
| Generate auth token      | Before deploy      | `openssl rand -hex 32`                        |
| Add token to builder     | Before deploy      | `just secret secrets/builder/core.yaml`       |
| Add token to house       | Before deploy      | `just secret secrets/house/core.yaml`         |
| Add files subdomain      | Before deploy      | Update private/identifiers/default.nix        |
| DNS record               | Before first use   | Add `files.<domain>` A record -> house IP     |
| Deploy house first       | Deploy time        | `just deploy-remote house` (frps gets auth)   |
| Deploy builder second    | Deploy time        | `just deploy` (frpc connects to updated frps) |
| Test sharing             | After deploy       | `just share-on`, visit https://files.<domain> |

## Usage

```sh
# Enable public sharing
just share-on

# Check if sharing is active
just share-status

# Disable public sharing
just share-off
```

When sharing is on, anyone with the URL `https://files.<domain>` can see
the Copyparty login page. They need the Copyparty username/password to
access files. When sharing is off, the URL returns a 502 gateway error.

## Future Considerations

- Read-only guest account: Add a second Copyparty user with read-only
  access to specific directories (e.g. `-a guest:PASS -v /media/b2/shared::r,guest`).
  This lets you share specific content without exposing admin access.
- Auto-off timer: Add a systemd timer that auto-stops the FRP client after
  N hours, so you don't forget to turn it off.
- Multiple tunnels: Other services on builder (or other machines) can
  register additional FRP proxies with different customDomains, all routed
  through the same frps on house.
