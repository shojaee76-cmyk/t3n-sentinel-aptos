#!/usr/bin/env bash
# Full on-chain deploy + verify sequence for t3n-sentinel-aptos on a localnet.
# Prereqs: `aptos node run-localnet` running (REST 8080, faucet 8081) and a
# profile named `localnet` (see README).
set -euo pipefail

V=0x635881fc5cba3d2dc158b08cb3b9f2be0ceea58f2b7360dcedd234e16c1264b8
PROFILE=localnet

echo "=== 1. Publish modules ==="
aptos move publish \
    --named-addresses "sentinel=$V" --profile "$PROFILE" --assume-yes

echo "=== 2. Vault: init + seal + probe ==="
aptos move run --function-id "$V::sentinel_vault::init" \
    --args "address:$V" "address:$V" --profile "$PROFILE" --assume-yes
aptos move run --function-id "$V::sentinel_vault::seal" \
    --args "address:$V" "string:github" "string:sk-test-123" \
    --profile "$PROFILE" --assume-yes
aptos move run --function-id "$V::sentinel_vault::record_probe" \
    --args "address:$V" "string:github" "u64:200" "string:" \
    --profile "$PROFILE" --assume-yes

echo "=== 3. Vault: list_providers + history ==="
aptos move view --function-id "$V::sentinel_vault::list_providers" \
    --args "address:$V" --profile "$PROFILE"
aptos move view --function-id "$V::sentinel_vault::history" \
    --args "address:$V" --profile "$PROFILE"

echo "=== 4. Oracle: init + attestation + probe ==="
aptos move run --function-id "$V::sentinel_oracle::init" \
    --args "address:$V" --profile "$PROFILE" --assume-yes
aptos move run --function-id "$V::sentinel_oracle::submit_attestation" \
    --args "address:$V" "string:github" "string:tdx" "string:digest-abc123" "u64:0" \
    --profile "$PROFILE" --assume-yes
aptos move view --function-id "$V::sentinel_oracle::is_verified" \
    --args "address:$V" "string:github" --profile "$PROFILE"
aptos move run --function-id "$V::sentinel_oracle::probe" \
    --args "address:$V" "string:github" "u64:200" "string:" \
    --profile "$PROFILE" --assume-yes

echo "=== 5. Payment: init + configure + paid probe ==="
aptos move run --function-id "$V::sentinel_payment::init" \
    --args "address:$V" "address:$V" --profile "$PROFILE" --assume-yes
aptos move run --function-id "$V::sentinel_payment::configure_provider" \
    --args "address:$V" "string:github" "address:$V" "u64:100" "bool:true" \
    --profile "$PROFILE" --assume-yes
aptos move view --function-id "$V::sentinel_payment::provider_config" \
    --args "address:$V" "string:github" --profile "$PROFILE"
aptos move run --function-id "$V::sentinel_payment::probe_with_payment" \
    --args "address:$V" "string:github" "u64:200" "string:paid-probe-ok" "u64:100" \
    --profile "$PROFILE" --assume-yes
aptos move view --function-id "$V::sentinel_payment::history" \
    --args "address:$V" --profile "$PROFILE"

echo "=== Done. ACL negative test (expect EUNKNOWN_PROVIDER abort): ==="
aptos move run --function-id "$V::sentinel_vault::record_probe" \
    --args "address:$V" "string:nope" "u64:200" "string:" \
    --profile "$PROFILE" --assume-yes || echo "OK: aborted as expected"
