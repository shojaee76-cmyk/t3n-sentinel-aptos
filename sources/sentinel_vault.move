/// sentinel_vault — Private API-key vault & health sentinel (Aptos Move port).
///
/// This module is the Aptos port of the T3N TEE WASM contract of the same
/// name (t3n-sentinel, contract id 741 on T3N testnet), and mirrors the
/// Solana Anchor (t3n-sentinel-solana), Starknet Cairo (t3n-sentinel-starknet)
/// and Soroban (t3n-sentinel-soroban) ports. The API shape is identical
/// (`init / seal / record_probe / list_providers / rotate / history /
/// get_secret / vault_info`); the storage model moves from a host-bound KV map
/// to Aptos global storage.
///
/// SECURITY MODEL
/// ==============
/// 1. Key material (the encrypted blob) is stored per (vault, provider) in
///    the `Secrets` table. The actual key material is held by a TEE worker
///    registered in the contract; the contract holds the access policy and
///    the audit log.
/// 2. A `tee_worker` address is the ONLY caller authorized to invoke
///    `record_probe` (the off-chain TEE adapter that does the HTTP probe).
/// 3. `History` is an append-only ring buffer (HISTORY_MAX = 16 entries).
/// 4. The probe functions NEVER return the API key — only the verdict
///    (VALID | INVALID | RATE_LIMITED | UNEXPECTED), matching the T3N egress
///    shape exactly.
///
/// MAINTENANCE CONTRACT
/// ====================
/// Adding a new provider = appending ONE entry to `providers`.
/// No schema migration, no client update. (Same as the other four ports.)
module sentinel::sentinel_vault {
    use std::option::{Self, Option};
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use aptos_framework::timestamp;
    use sentinel::sentinel_types;

    /// Ring-buffer capacity — matches HISTORY_MAX in the Solana (16),
    /// Starknet (16) and Soroban (16) ports.
    const HISTORY_MAX: u64 = 16;

    /// Vault not initialized.
    const ENOT_INITIALIZED: u64 = 1;
    /// Caller is not the vault authority.
    const ENOT_AUTHORITY: u64 = 2;
    /// Caller is not the registered TEE worker.
    const ENOT_TEE_WORKER: u64 = 3;
    /// Unknown provider name.
    const EUNKNOWN_PROVIDER: u64 = 4;
    /// Empty secret blob.
    const EEMPTY_SECRET: u64 = 5;
    /// Provider has no sealed secret yet.
    const ENOT_SEALED: u64 = 6;

    /// One sealed secret per (vault, provider).
    struct SecretEntry has store, copy, drop {
        provider: String,
        secret_blob: String,
        sealed_at: u64,
    }

    /// One row of `list_providers`.
    struct ProviderRow has store, copy, drop {
        provider: String,
        sealed: bool,
        last_verdict: Option<sentinel_types::ProbeReceipt>,
    }

    /// Vault global state. `authority` seals/rotates; `tee_worker` records
    /// probes and reads secrets; `secrets` is the per-provider secret table;
    /// `history` is the ring buffer; `history_count` tracks the live length.
    struct SentinelVault has key {
        authority: address,
        tee_worker: address,
        secrets: vector<SecretEntry>,
        history: vector<sentinel_types::ProbeReceipt>,
        history_count: u64,
    }

    /// Create the vault under `creator`'s signer. Authority and TEE worker are
    /// set to the creator by default; the caller can re-seal/rotate later.
    /// Aborts if a vault already exists for this address.
    public entry fun init(creator: &signer, authority: address, tee_worker: address) {
        let addr = signer::address_of(creator);
        assert!(!exists<SentinelVault>(addr), ENOT_INITIALIZED);
        move_to(
            creator,
            SentinelVault {
                authority,
                tee_worker,
                secrets: vector::empty(),
                history: vector::empty(),
                history_count: 0,
            },
        );
    }

    /// Write a new API key (encrypted blob) into the vault under `provider`.
    /// Only the vault authority may seal. Aborts on unknown provider or empty
    /// key.
    public entry fun seal(creator: &signer, vault_addr: address, provider: String, secret_blob: String) {
        assert!(exists<SentinelVault>(vault_addr), ENOT_INITIALIZED);
        let vault = borrow_global_mut<SentinelVault>(vault_addr);
        assert!(signer::address_of(creator) == vault.authority, ENOT_AUTHORITY);
        assert!(sentinel_types::is_known_provider(&provider), EUNKNOWN_PROVIDER);
        assert!(string::length(&secret_blob) > 0, EEMPTY_SECRET);
        let entry = SecretEntry {
            provider: provider,
            secret_blob: secret_blob,
            sealed_at: timestamp::now_seconds(),
        };
        upsert_secret(vault, entry);
    }

    /// Called by the registered TEE worker after running the authenticated
    /// HTTP probe off-chain. Classifies the HTTP status and appends a
    /// ProbeReceipt into the history ring buffer. Aborts unless the caller is
    /// the registered TEE worker.
    public entry fun record_probe(
        creator: &signer,
        vault_addr: address,
        provider: String,
        http_code: u64,
        detail: String,
    ) {
        assert!(exists<SentinelVault>(vault_addr), ENOT_INITIALIZED);
        let vault = borrow_global_mut<SentinelVault>(vault_addr);
        assert!(signer::address_of(creator) == vault.tee_worker, ENOT_TEE_WORKER);
        assert!(sentinel_types::is_known_provider(&provider), EUNKNOWN_PROVIDER);

        let (verdict, default_detail) = sentinel_types::classify(http_code);
        let detail_final = if (string::length(&detail) == 0) {
            default_detail
        } else {
            detail
        };
        let receipt = sentinel_types::new_receipt(
            provider,
            verdict,
            http_code,
            detail_final,
            timestamp::now_seconds(),
        );
        // Append to the ring buffer; shift left when full.
        if (vector::length(&vault.history) >= HISTORY_MAX) {
            vector::remove(&mut vault.history, 0);
        };
        vector::push_back(&mut vault.history, receipt);
        vault.history_count = vector::length(&vault.history);
    }

    /// Snapshot of which providers are sealed, plus the last verdict for
    /// each. Mirrors the Solana/Starknet/Soroban `list_providers`.
#[view]
    public fun list_providers(vault_addr: address): vector<ProviderRow> {
        assert!(exists<SentinelVault>(vault_addr), ENOT_INITIALIZED);
        let vault = borrow_global<SentinelVault>(vault_addr);
        let rows = vector::empty();
        let names = sentinel_types::provider_names();
        let n = vector::length(&names);
        let i = 0;
        while (i < n) {
            let name = *vector::borrow(&names, i);
            let sealed = is_sealed(vault, &name);
            let last = last_verdict(vault, &name);
            vector::push_back(&mut rows, ProviderRow {
                provider: name,
                sealed,
                last_verdict: last,
            });
            i = i + 1;
        };
        rows
    }

    /// Getter: provider name of a row.
    public fun row_provider(row: &ProviderRow): String {
        row.provider
    }

    /// Getter: sealed flag of a row.
    public fun row_sealed(row: &ProviderRow): bool {
        row.sealed
    }

    /// Getter: last verdict of a row.
    public fun row_last_verdict(row: &ProviderRow): Option<sentinel_types::ProbeReceipt> {
        row.last_verdict
    }

    /// Seal a new blob over an existing provider entry. Same ACL as `seal`.
    /// Aborts if the provider was never sealed.
    public entry fun rotate(creator: &signer, vault_addr: address, provider: String, new_blob: String) {
        assert!(exists<SentinelVault>(vault_addr), ENOT_INITIALIZED);
        let vault = borrow_global_mut<SentinelVault>(vault_addr);
        assert!(signer::address_of(creator) == vault.authority, ENOT_AUTHORITY);
        assert!(sentinel_types::is_known_provider(&provider), EUNKNOWN_PROVIDER);
        assert!(string::length(&new_blob) > 0, EEMPTY_SECRET);
        assert!(is_sealed(vault, &provider), ENOT_SEALED);
        let entry = SecretEntry {
            provider: provider,
            secret_blob: new_blob,
            sealed_at: timestamp::now_seconds(),
        };
        upsert_secret(vault, entry);
    }

    /// Return the ring buffer's entries, newest first.
#[view]
    public fun history(vault_addr: address): vector<sentinel_types::ProbeReceipt> {
        assert!(exists<SentinelVault>(vault_addr), ENOT_INITIALIZED);
        let vault = borrow_global<SentinelVault>(vault_addr);
        let out = vector::empty();
        let len = vector::length(&vault.history);
        let i = len;
        while (i > 0) {
            let receipt = *vector::borrow(&vault.history, i - 1);
            vector::push_back(&mut out, receipt);
            i = i - 1;
        };
        out
    }

    /// Fetch the encrypted blob for a provider. Only the registered TEE
    /// worker may read blobs. Aborts otherwise. (Non-entry: returns a value.)
    public fun get_secret(creator: &signer, vault_addr: address, provider: String): String {
        assert!(exists<SentinelVault>(vault_addr), ENOT_INITIALIZED);
        let vault = borrow_global<SentinelVault>(vault_addr);
        assert!(signer::address_of(creator) == vault.tee_worker, ENOT_TEE_WORKER);
        assert!(sentinel_types::is_known_provider(&provider), EUNKNOWN_PROVIDER);
        let entry = find_secret(vault, &provider);
        assert!(entry.is_some(), ENOT_SEALED);
        let entry = *option::borrow(&entry);
        entry.secret_blob
    }

    /// authority + tee_worker + sealed count (read-only).
#[view]
    public fun vault_info(vault_addr: address): (address, address, u64) {
        assert!(exists<SentinelVault>(vault_addr), ENOT_INITIALIZED);
        let vault = borrow_global<SentinelVault>(vault_addr);
        (vault.authority, vault.tee_worker, sealed_count(vault))
    }

    /// Friend accessor used by sentinel_payment to append paid receipts into
    /// the same ring buffer.
    public(friend) fun friend_append_receipt(vault_addr: address, receipt: sentinel_types::ProbeReceipt) {
        assert!(exists<SentinelVault>(vault_addr), ENOT_INITIALIZED);
        let vault = borrow_global_mut<SentinelVault>(vault_addr);
        if (vector::length(&vault.history) >= HISTORY_MAX) {
            vector::remove(&mut vault.history, 0);
        };
        vector::push_back(&mut vault.history, receipt);
        vault.history_count = vector::length(&vault.history);
    }

    // --- internal helpers ---

    fun is_sealed(vault: &SentinelVault, provider: &String): bool {
        let n = vector::length(&vault.secrets);
        let i = 0;
        while (i < n) {
            if (sentinel_types::string_eq(&vector::borrow(&vault.secrets, i).provider, provider)) {
                return true;
            };
            i = i + 1;
        };
        false
    }

    fun find_secret(vault: &SentinelVault, provider: &String): Option<SecretEntry> {
        let n = vector::length(&vault.secrets);
        let i = 0;
        while (i < n) {
            let entry = vector::borrow(&vault.secrets, i);
            if (sentinel_types::string_eq(&entry.provider, provider)) {
                return option::some(*entry);
            };
            i = i + 1;
        };
        option::none()
    }

    fun upsert_secret(vault: &mut SentinelVault, entry: SecretEntry) {
        let n = vector::length(&vault.secrets);
        let i = 0;
        while (i < n) {
            let existing = vector::borrow_mut(&mut vault.secrets, i);
            if (sentinel_types::string_eq(&existing.provider, &entry.provider)) {
                *existing = entry;
                return;
            };
            i = i + 1;
        };
        vector::push_back(&mut vault.secrets, entry);
    }

    fun last_verdict(vault: &SentinelVault, provider: &String): Option<sentinel_types::ProbeReceipt> {
        let len = vector::length(&vault.history);
        let i = len;
        while (i > 0) {
            let receipt = vector::borrow(&vault.history, i - 1);
            if (sentinel_types::string_eq(&sentinel_types::receipt_provider(receipt), provider)) {
                return option::some(*receipt);
            };
            i = i - 1;
        };
        option::none()
    }

    fun sealed_count(vault: &SentinelVault): u64 {
        vector::length(&vault.secrets)
    }
}
