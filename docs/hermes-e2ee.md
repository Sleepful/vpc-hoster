# Hermes Agent E2EE Debugging

Known bugs, gotchas, and recovery procedures for Hermes Agent Matrix E2EE on NixOS.

## Known version bug

Hermes 0.15.1 (mautrix adapter) has a silent OTK upload failure with access token login. The `handle_sync()` call is missing from the initial sync, so the `OlmMachine` never receives the `DEVICE_OTK_COUNT` event that triggers one-time key generation. Password login uses a different code path where OTK upload succeeds. PR #10860 (merged April 2026) partially addresses this but isn't in 0.15.1. Updating the `hermes-agent` flake input may help.

## Stable device ID

`MATRIX_DEVICE_ID` works with password login but requires a clean start. If you add it to an account that already has a different device, delete `crypto.db` to avoid `BAD_ACCOUNT_KEY` errors. The first boot with a fresh device ID creates matching device keys and OTKs — the conflict only happens on reuse.

## Cross-signing recovery key

The recovery key must match the server's SSSS data exactly. Never delete `e2e_cross_signing_keys` or cross-signing `account_data` rows after an Element cross-signing reset — this corrupts the SSSS and makes the recovery key unrecoverable. If the SSSS is corrupted, the bot silently refuses to verify.

## Full clean reset

When stuck in an OTK or cross-signing loop, wipe everything:

```sql
DELETE FROM devices WHERE user_id = '@bot:example.com';
DELETE FROM e2e_one_time_keys_json WHERE user_id = '@bot:example.com';
DELETE FROM e2e_device_keys_json WHERE user_id = '@bot:example.com';
DELETE FROM e2e_cross_signing_keys WHERE user_id = '@bot:example.com';
DELETE FROM e2e_cross_signing_signatures WHERE user_id = '@bot:example.com';
DELETE FROM account_data WHERE user_id = '@bot:example.com'
  AND (account_data_type LIKE 'm.cross_signing%'
    OR account_data_type IN ('m.megolm_backup.v1','m.secret_storage.default_key'));
```

Then: delete `crypto.db`, reset cross-signing in Element, capture new key, deploy with `MATRIX_RECOVERY_KEY`. On first startup, hermes imports cross-signing from SSSS and signs its device.

## Working configuration

```nix
# secrets.nix template — hermes-env
MATRIX_HOMESERVER=https://matrix.example.com
MATRIX_USER_ID=@bot:example.com
MATRIX_PASSWORD=<sops:matrix_password>
MATRIX_ALLOWED_USERS=@admin:example.com
MATRIX_RECOVERY_KEY=<sops:matrix_recovery_key>
MATRIX_ENCRYPTION=true
MATRIX_DEVICE_ID=HERMES_BOT
```

## Common error messages

| Message | Meaning | Fix |
|---------|---------|-----|
| `BAD_ACCOUNT_KEY` | crypto.db device ID doesn't match env | Delete crypto.db, restart |
| `No default key ID set` | SSSS is empty/corrupted | Reset cross-signing in Element |
| `signed_curve25519:XXX already exists` | OTK ID collision (stale keys) | Delete OTKs from DB, restart |
| `matrix failed to connect` | Generic connection failure | Check logs for root cause above |
| `recovery key verification failed` | Recovery key doesn't match SSSS | Re-reset cross-signing, capture fresh key |
