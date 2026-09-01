# t3n-sentinel-aptos

**Aptos (Move) port of t3n-sentinel — the "one architecture, N chains" agent key
vault & health sentinel.** Chain #5 in the portfolio:

| Chain | Language | Status | Repo |
|---|---|---|---|
| T3N (TEE) | WASM | **LIVE** (contract id 741) | `t3n-sentinel` |
| Solana | Anchor (Rust) | 20/20 tests, SBF built, local-validator verified | `t3n-sentinel-solana` |
| Starknet | Cairo | 43/43 tests, Sepolia live | `t3n-sentinel-starknet` |
| Stellar | Soroban | 51/51 tests, testnet live | `t3n-sentinel-soroban` |
| **Aptos** | **Move** | **42/42 tests, localnet deployed + verified** | **this repo** |

---

## What it is

A private API-key vault & health sentinel for AI agents. The T3N reference
implementation runs inside a TEE (contract id 741 on T3N testnet) and holds an
agent's API keys; this port reproduces the exact same contract surface on Aptos
Move:

- **`sentinel_vault`** — ACL'd vault (authority seals/rotates keys, a registered
  TEE worker records probe results), append-only ring-buffer history (16 entries),
  HTTP-status classifier, and a `list_providers` snapshot.
- **`sentinel_oracle`** — operator-gated TEE attestation oracle. The off-chain
  verifier (Phala / Nillion / TDX / SGX) submits a validated attestation digest;
  the contract enforces a **per-epoch replay guard** and emits a `ProbeFired`
  event only for verified providers.
- **`sentinel_payment`** — APT micropayment rail. Per-provider payout address +
  price (octas) + paywalled flag. When paywalled, the probe is only recorded
  **after** the APT transfer succeeds — "no probe without payment when paywalled"
  holds by construction.

Aptos's native **gasless sponsored transactions + account abstraction** pair
naturally with the sentinel's per-probe micropayment rail — the same pitch angle
as the Soroban `sentinel-payment` and Starknet account-abstraction work.

## Security model

1. Key material (the encrypted blob) is stored per (vault, provider). The real
   key lives inside the TEE worker; the contract holds the access policy + audit log.
2. The registered `tee_worker` is the ONLY caller authorized to `record_probe`
   (verified on-chain: non-worker calls abort with `ENOT_TEE_WORKER`).
3. `history` is an append-only ring buffer capped at 16 (matches all ports).
4. Probe functions NEVER return the API key — only the verdict
   (`VALID | INVALID | RATE_LIMITED | UNEXPECTED`).

## Test suite

```bash
aptos move test --named-addresses sentinel=0xcafe
```

```
Test result: OK. Total tests: 42; passed: 42; failed: 0
```

| Module | Tests | Coverage |
|---|---|---|
| `sentinel_vault_tests` | 16 | init/ACL, seal (authority-gated, unknown-provider, empty-key aborts), record_probe (classify 200/401/429/500, custom detail, worker-only, unknown-provider), ring-buffer cap 16, list_providers, rotate, get_secret |
| `sentinel_oracle_tests` | 11 | init, submit_attestation (operator-gated, stale-epoch, replay, unknown-type aborts), probe (verified emits event / unverified aborts), rotate_epoch invalidation, is_verified, attestation_digest |
| `sentinel_payment_tests` | 11 | init, configure_provider (authority-gated, unknown-provider), free probe, paywalled probe (without payment aborts, wrong amount aborts, exact payment succeeds + balance drops) |
| `sentinel_types_tests` | 4 | classifier mapping, provider registry, string_eq |

## On-chain deployment

Deployed on an Aptos **localnet** (single-node, `aptos node run-localnet`) —
the public testnet/devnet faucets now require Google sign-in (JWT), so a
localnet with its own faucet is the reproducible, faucet-free path (same
approach as the Solana port's local-validator proof).

- **Deployer / authority / tee_worker**: `0x635881fc5cba3d2dc158b08cb3b9f2be0ceea58f2b7360dcedd234e16c1264b8`
- **Modules published** (version 67, then upgraded with `#[view]` fns): `sentinel_types`,
  `sentinel_vault`, `sentinel_oracle`, `sentinel_payment`, `aptos_account`

### On-chain verified flow (all via the REST API at 127.0.0.1:8080)

```
1. init(vault)                     → success (version 95)
2. seal(github, sk-test-123)       → success (version 106)
3. record_probe(github, 200)       → success (version 119)
4. list_providers(vault)           → github: sealed=true, last_verdict=VALID/200
                                     groq/openrouter/openai: sealed=false
5. history(vault)                  → [{provider: github, verdict: VALID,
                                      http_code: 200, detail: "key accepted by provider",
                                      checked_at: 1788301252}]
6. vault_info(vault)               → (deployer, deployer, 1)
7. init(oracle) → submit_attestation(github, tdx, digest-abc123, epoch 0)
   → is_verified(github) = true, epoch = 0
8. probe(github, 200)              → success; on-chain event:
   ProbeFired { provider: "github", verdict: "VALID", http_code: "200", epoch: "0" }
9. init(payment) → configure_provider(github, payout=deployer, price=100, paywalled=true)
   → provider_config = {payout, paywalled: true, price: 100}
10. probe_with_payment(github, 200, "paid-probe-ok", 100)
    → success; payment history = [{...detail: "paid-probe-ok", verdict: VALID}];
      deployer balance 86,964,400 → 86,935,900 (100 octas paid + gas)
11. ACL negative: record_probe(nope) → Move abort EUNKNOWN_PROVIDER(0x4)
```

## Reproduce

```bash
# 1. Start a localnet (own faucet, no auth)
aptos node run-localnet --force-restart --test-dir .aptos/localnet

# 2. Create + fund a profile
aptos init --network custom --rest-url http://127.0.0.1:8080 \
    --faucet-url http://127.0.0.1:8081 --assume-yes --profile localnet

# 3. Publish
aptos move publish \
    --named-addresses sentinel=<your-address> --profile localnet --assume-yes

# 4. Run the on-chain flow (scripts/deploy_localnet.sh has the full sequence)
```

See `scripts/deploy_localnet.sh` for the complete init → seal → probe → list →
history → oracle → payment sequence.

## Layout

```
sources/
  sentinel_types.move       # shared classifier + provider registry + receipt struct
  sentinel_vault.move       # ACL'd vault, ring-buffer history
  sentinel_oracle.move      # operator-gated attestation oracle + ProbeFired event
  sentinel_payment.move     # APT micropayment rail
  sentinel_*_tests.move     # 42 native Move tests
  aptos_account.move        # account helper
Move.toml                   # local framework dep (aptos-cli-v9.5.1 tag)
scripts/deploy_localnet.sh  # full on-chain deploy + verify sequence
```

## License

MIT
