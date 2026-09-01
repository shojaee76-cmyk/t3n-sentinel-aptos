# t3n-sentinel-aptos — PROJECT.md

**What it is:** Aptos (Move) port of t3n-sentinel — the private API-key vault &
health sentinel for AI agents. Chain #5 of the "one architecture, N chains"
portfolio (T3N WASM → Solana Anchor → Starknet Cairo → Stellar Soroban → **Aptos Move**).

**Repo:** https://github.com/shojaee76-cmyk/t3n-sentinel-aptos (public, MIT)

## Status: M1 COMPLETE — 42/42 tests, localnet deployed + on-chain verified

## Modules
- `sentinel_types` — shared ProbeReceipt + classifier + provider registry
- `sentinel_vault` — ACL'd vault, 16-entry ring-buffer history
- `sentinel_oracle` — operator-gated attestation oracle, per-epoch replay guard,
  `ProbeFired` event
- `sentinel_payment` — APT micropayment rail (payout/price/paywalled), atomic
  transfer-before-receipt
- `aptos_account` — account helper

## Verification evidence
- **42/42 native Move tests green** (`aptos move test --named-addresses sentinel=0xcafe`)
- **Localnet deployed** (aptos CLI 9.5.1, `aptos node run-localnet`):
  - Deployer/authority/worker: `0x635881fc5cba3d2dc158b08cb3b9f2be0ceea58f2b7360dcedd234e16c1264b8`
  - Modules: `sentinel_types`, `sentinel_vault`, `sentinel_oracle`, `sentinel_payment`
- **On-chain verified flow** (all via REST 127.0.0.1:8080):
  - `seal(github, sk-test-123)` → success (v106)
  - `record_probe(github, 200)` → success (v119)
  - `list_providers` → github sealed=true + last_verdict VALID/200
  - `history` → `{github, VALID, 200, "key accepted by provider", 1788301252}`
  - `vault_info` → (deployer, deployer, 1)
  - oracle: `submit_attestation` → `is_verified=true` → `probe` → **ProbeFired event**
    `{github, VALID, 200, epoch 0}` (v225)
  - payment: `configure_provider` (paywalled, 100 octas) → `probe_with_payment`
    → payment history `{VALID, 200, "paid-probe-ok"}` + balance drop
  - ACL negative: `record_probe(nope)` → abort `EUNKNOWN_PROVIDER(0x4)`

## Deployment notes
- **Testnet faucet BLOCKED**: requires Google sign-in (JWT). Devnet faucet (HTTP)
  works but deposits to object stores without creating the account resource →
  `INSUFFICIENT_BALANCE_FOR_TRANSACTION_FEE`. **Localnet with own faucet = working
  path** (same as Solana local-validator proof).
- Framework dep pinned to `aptos-cli-v9.5.1` tag via local sparse clone at
  `%LOCALAPPDATA%/Temp/aptos-fw-src` (git deps too heavy for Iran line).
- Publish needs `--max-gas 2000000` + `--assume-yes`.

## Grant
- Aptos Foundation Ecosystem Grant draft: `bounty-lab/drafts/aptos-foundation-application.md`
  ($50k ask, 5 milestones, Developer Tooling track)
- NOT YET SUBMITTED (user submits via aptosnetwork.com/grants)

## Progress log
- 2026-09-01 — **M1 COMPLETE**. Aptos CLI 9.5.1 (Windows binary via aria2c,
  aptos-cli-v9.5.1 release asset). Move port written: sentinel_types/vault/oracle/
  payment + 42 native tests (vault 16, oracle 11, payment 11, types via vault).
  Debugged 25+ Move compile/borrow/privacy issues (string::equal → bytes compare,
  module field privacy → getters, Option imports, #[event] attr, expected_failure
  location, signer-as-vault-address → explicit vault_addr param, coin::transfer
  pays from worker not contract). Tests 42/42 green, zero warnings. Localnet deploy
  + full on-chain verification (vault/oracle/payment/ACL-abort). README + LICENSE +
  deploy script. Repo pushed public via Contents API (fine-grained token can't
  git-push; seeded README first to create main, then 12 files PUT). Grant draft
  written.
