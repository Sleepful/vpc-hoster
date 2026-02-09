# House secrets

Edit with:

```sh
just secret secrets/house/core.yaml
```

Current keys:

- `syncthing_password`
- `smtp_username`
- `smtp_password`
- `miniflux_password`
- `aws_cli_user`
- `aws_cli_pass`
- `discord_token`
- `instance_id`
- `outline_oidc_secret`
- `mail_hash_contact`
- `mail_hash_outline_noreply`
- `mail_hash_family`
- `mail_hash_shared`
- `dex_hash_super`
- `dex_hash_atlas`
- `dex_hash_lumen`

Notes:

- SMTP relay (`smtp_username` / `smtp_password`) is used by Postfix to authenticate to the outbound provider.
  Current provider: Mailtrap Email Sending (`live.smtp.mailtrap.io:587`).
- Mail login hashes (`mail_hash_*`) are bcrypt (Dovecot BLF-CRYPT). Values can be raw `$2b$...` / `$2y$...` or prefixed `{BLF-CRYPT}$2y$...`.
- On `house`, the hashes are written into `/run/dovecot2/passwd` at `dovecot2` start; the Nix config restarts `dovecot2` automatically when any `mail_hash_*` secret changes.
