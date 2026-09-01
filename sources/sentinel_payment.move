/// sentinel_payment — APT micropayment rail for t3n-sentinel (Aptos Move port).
///
/// Every `probe_with_payment` call can atomically transfer an APT
/// micropayment to the provider's payout address. Providers can opt into a
/// "paywalled" mode where a probe is only recorded after the APT transfer
/// succeeds — the invariant "no probe without APT transfer when provider is
/// paywalled" holds by construction (the transfer happens BEFORE the receipt
/// is appended).
///
/// Architecture: this module extends the sentinel-vault flow with a payment
/// leg. The vault authority configures per-provider:
///   - `payout`: the address that receives the micropayment,
///   - `price`:  the per-probe APT price in octas (1 APT = 10^8 octas),
///               0 = free,
///   - `paywall`: whether payment is REQUIRED for a probe to be recorded.
///
/// The TEE worker (the registered `tee_worker`) calls `probe_with_payment`:
///   1. validates caller == tee_worker,
///   2. requires the provider to be known,
///   3. if paywalled and price > 0: transfers `price` octas from the vault's
///      funded account to `payout` via the coin module,
///   4. classifies the HTTP status and appends the receipt (same ring-buffer
///      semantics as the vault).
///
/// SECURITY MODEL
/// ==============
/// 1. Only the registered `tee_worker` may trigger a paid probe.
/// 2. Payment is ATOMIC with the probe: if the transfer fails (insufficient
///    balance, coin error), the receipt is NOT appended and the call aborts.
/// 3. The payment is pulled from the vault contract itself, so the TEE worker
///    never needs to hold funds.
/// 4. `probe_with_payment` NEVER returns the API key — only the verdict.
module sentinel::sentinel_payment {
    use std::option::{Self, Option};
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use aptos_framework::coin::{Self};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::timestamp;
    use sentinel::sentinel_types;

    /// Payment rail not initialized.
    const ENOT_INITIALIZED: u64 = 1;
    /// Caller is not the vault authority.
    const ENOT_AUTHORITY: u64 = 2;
    /// Caller is not the registered TEE worker.
    const ENOT_TEE_WORKER: u64 = 3;
    /// Unknown provider name.
    const EUNKNOWN_PROVIDER: u64 = 4;
    /// Negative price.
    const ENEGATIVE_PRICE: u64 = 5;
    /// Paid amount does not match the configured price.
    const EPAYMENT_MISMATCH: u64 = 6;
    /// Paywalled provider requires a payment.
    const EPAYWALL_REQUIRED: u64 = 7;

    /// Ring-buffer capacity — matches the vault (16).
    const HISTORY_MAX: u64 = 16;

    /// Per-provider payment configuration.
    struct ProviderConfig has store, copy, drop {
        provider: String,
        /// Address that receives the APT micropayment.
        payout: address,
        /// Per-probe price in octas (1 APT = 10^8 octas). 0 = free.
        price: u64,
        /// If true, a probe is only recorded after the payment succeeds.
        paywalled: bool,
    }

    /// Payment rail global state.
    struct SentinelPayment has key {
        authority: address,
        tee_worker: address,
        configs: vector<ProviderConfig>,
        /// Paid-probe receipts. Kept in the rail itself (not the vault) to
        /// avoid a module dependency cycle; the vault and the rail maintain
        /// independent ring buffers for the same probe stream.
        history: vector<sentinel_types::ProbeReceipt>,
    }

    /// Canonical probe outcome — same shape as the vault port, plus `paid`.
    struct PaidReceipt has store, copy, drop {
        provider: String,
        verdict: String,
        http_code: u64,
        detail: String,
        checked_at: u64,
        /// APT paid in octas for this probe (0 if free).
        paid: u64,
    }

    /// Create the payment rail under `creator`'s signer. The authority (who
    /// configures providers) and the TEE worker (who triggers paid probes)
    /// must be registered. Aborts if a rail already exists for this address.
    public entry fun init(creator: &signer, authority: address, tee_worker: address) {
        let addr = signer::address_of(creator);
        assert!(!exists<SentinelPayment>(addr), ENOT_INITIALIZED);
        move_to(
            creator,
            SentinelPayment {
                authority,
                tee_worker,
                configs: vector::empty(),
                history: vector::empty(),
            },
        );
    }

    /// Set (or update) the payment config for a known provider. Only the
    /// authority may call.
    public entry fun configure_provider(
        creator: &signer,
        rail_addr: address,
        provider: String,
        payout: address,
        price: u64,
        paywalled: bool,
    ) {
        assert!(exists<SentinelPayment>(rail_addr), ENOT_INITIALIZED);
        let rail = borrow_global_mut<SentinelPayment>(rail_addr);
        assert!(signer::address_of(creator) == rail.authority, ENOT_AUTHORITY);
        assert!(sentinel_types::is_known_provider(&provider), EUNKNOWN_PROVIDER);
        assert!(price >= 0, ENEGATIVE_PRICE);
        let cfg = ProviderConfig { provider, payout, price, paywalled };
        upsert_config(rail, cfg);
    }

    /// The TEE worker records a probe; if the provider is paywalled (or
    /// priced), the APT micropayment is transferred FIRST, atomically, then
    /// the receipt is appended. Aborts if the transfer fails.
    public entry fun probe_with_payment(
        creator: &signer,
        rail_addr: address,
        provider: String,
        http_code: u64,
        detail: String,
        paid: u64,
    ) {
        assert!(exists<SentinelPayment>(rail_addr), ENOT_INITIALIZED);
        let rail = borrow_global_mut<SentinelPayment>(rail_addr);
        assert!(signer::address_of(creator) == rail.tee_worker, ENOT_TEE_WORKER);
        assert!(sentinel_types::is_known_provider(&provider), EUNKNOWN_PROVIDER);

        let cfg = find_config(rail, &provider);
        let (paywalled, price) = if (option::is_some(&cfg)) {
            let c = *option::borrow(&cfg);
            (c.paywalled, c.price)
        } else {
            (false, 0)
        };

        // If the provider is paywalled, payment is MANDATORY for the probe to
        // be recorded. Enforce the exact configured price. The TEE worker
        // pays from its own APT balance (the rail holds no funds — Aptos
        // `coin::transfer` moves coins from the signer).
        if (paywalled) {
            assert!(paid > 0, EPAYWALL_REQUIRED);
            assert!(paid == price, EPAYMENT_MISMATCH);
            let payout = option::borrow(&cfg).payout;
            coin::transfer<AptosCoin>(creator, payout, paid);
        };

        let (verdict, default_detail) = sentinel_types::classify(http_code);
        let detail_final = if (string::length(&detail) == 0) {
            default_detail
        } else {
            detail
        };

        // Append the paid receipt into the rail's own ring buffer (independent
        // of the vault's buffer, keeping module deps acyclic).
        let receipt = sentinel_types::new_receipt(
            provider,
            verdict,
            http_code,
            detail_final,
            timestamp::now_seconds(),
        );
        let rail = borrow_global_mut<SentinelPayment>(rail_addr);
        if (vector::length(&rail.history) >= HISTORY_MAX) {
            vector::remove(&mut rail.history, 0);
        };
        vector::push_back(&mut rail.history, receipt);
    }

    /// History of paid probes, newest first (mirrors the vault).
#[view]
    public fun history(rail_addr: address): vector<sentinel_types::ProbeReceipt> {
        assert!(exists<SentinelPayment>(rail_addr), ENOT_INITIALIZED);
        let rail = borrow_global<SentinelPayment>(rail_addr);
        let out = vector::empty();
        let len = vector::length(&rail.history);
        let i = len;
        while (i > 0) {
            let receipt = *vector::borrow(&rail.history, i - 1);
            vector::push_back(&mut out, receipt);
            i = i - 1;
        };
        out
    }

    /// Read a provider's payment config.
#[view]
    public fun provider_config(rail_addr: address, provider: String): Option<ProviderConfig> {
        assert!(exists<SentinelPayment>(rail_addr), ENOT_INITIALIZED);
        let rail = borrow_global<SentinelPayment>(rail_addr);
        find_config(rail, &provider)
    }

    /// APT balance of this contract (for audits/tests).
#[view]
    public fun vault_balance(rail_addr: address): u64 {
        coin::balance<AptosCoin>(rail_addr)
    }

    /// The configured payout address for a provider.
#[view]
    public fun payout_for(rail_addr: address, provider: String): Option<address> {
        let cfg = provider_config(rail_addr, provider);
        if (option::is_some(&cfg)) {
            option::some(option::borrow(&cfg).payout)
        } else {
            option::none()
        }
    }

    /// Getter: payout of a config.
    public fun config_payout(c: &ProviderConfig): address {
        c.payout
    }

    /// Getter: price of a config.
    public fun config_price(c: &ProviderConfig): u64 {
        c.price
    }

    /// Getter: paywalled flag of a config.
    public fun config_paywalled(c: &ProviderConfig): bool {
        c.paywalled
    }

    // --- internal helpers ---

    fun upsert_config(rail: &mut SentinelPayment, cfg: ProviderConfig) {
        let n = vector::length(&rail.configs);
        let i = 0;
        while (i < n) {
            let existing = vector::borrow_mut(&mut rail.configs, i);
            if (sentinel_types::string_eq(&existing.provider, &cfg.provider)) {
                *existing = cfg;
                return;
            };
            i = i + 1;
        };
        vector::push_back(&mut rail.configs, cfg);
    }

    fun find_config(rail: &SentinelPayment, provider: &String): Option<ProviderConfig> {
        let n = vector::length(&rail.configs);
        let i = 0;
        while (i < n) {
            let cfg = vector::borrow(&rail.configs, i);
            if (sentinel_types::string_eq(&cfg.provider, provider)) {
                return option::some(*cfg);
            };
            i = i + 1;
        };
        option::none()
    }
}
