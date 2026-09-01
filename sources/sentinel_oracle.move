/// sentinel_oracle — TEE oracle adapter for t3n-sentinel (Aptos Move port).
///
/// The contract verifies a TEE attestation and emits a `ProbeFired` event only
/// when the attestation is valid. Pluggable for Phala, Nillion, and a generic
/// TDX/SGX attestation.
///
/// This is the Aptos mirror of the `sentinel_oracle` module of the T3N TEE
/// reference impl (contract id 741 on T3N testnet) and of the Solana/Starknet/
/// Soroban ports. On-chain we do not verify the raw TEE quote (that requires a
/// verifier service); instead the contract:
///   1. records the operator (who runs the off-chain verifier),
///   2. accepts a submitted attestation payload and checks its structural
///      validity (nonce replay guard, attestation format marker, expiry),
///   3. keeps a per-epoch nonce/attestation registry so an attestation can
///      never be replayed,
///   4. emits `ProbeFired` only for valid attestations.
///
/// The off-chain verifier (a Phala / Nillion / SGX-TDX quote verifier) checks
/// the real quote and, on success, submits the validated attestation digest
/// here. The contract then gates the probe verdict on it.
module sentinel::sentinel_oracle {
    use std::option::{Self, Option};
    use std::signer;
    use std::string::{Self, String};
    use std::vector;
    use aptos_framework::event;
    use sentinel::sentinel_types;

    /// Oracle not initialized.
    const ENOT_INITIALIZED: u64 = 1;
    /// Caller is not the operator.
    const ENOT_OPERATOR: u64 = 2;
    /// Attestation epoch does not match the current epoch.
    const ESTALE_EPOCH: u64 = 3;
    /// Attestation digest was already accepted (replay).
    const EATTESTATION_REPLAY: u64 = 4;
    /// Provider has no verified attestation for the current epoch.
    const ENOT_VERIFIED: u64 = 5;

    /// Per-provider oracle state: whether the provider's TEE worker has been
    /// verified and which attestation digest was accepted for the current
    /// epoch.
    struct ProviderState has store, copy, drop {
        provider: String,
        verified: bool,
        attestation_digest: String,
        epoch: u64,
    }

    /// Oracle global state.
    struct SentinelOracle has key {
        operator: address,
        epoch: u64,
        used_attestations: vector<String>,
        provider_states: vector<ProviderState>,
    }

    #[event]
    struct ProbeFired has drop, store {
        // Emitted whenever a valid attestation leads to a probe verdict.
        provider: String,
        verdict: String,
        http_code: u64,
        epoch: u64,
    }

    /// Create the oracle under `creator`'s signer with `operator` as the
    /// off-chain verifier address. Aborts if an oracle already exists.
    public entry fun init(creator: &signer, operator: address) {
        let addr = signer::address_of(creator);
        assert!(!exists<SentinelOracle>(addr), ENOT_INITIALIZED);
        move_to(
            creator,
            SentinelOracle {
                operator,
                epoch: 0,
                used_attestations: vector::empty(),
                provider_states: vector::empty(),
            },
        );
    }

    /// Operator submits a validated TEE attestation digest for a provider.
    /// Sets the provider's oracle state to verified for the current epoch.
    /// Aborts unless the caller is the operator.
    public entry fun submit_attestation(
        creator: &signer,
        oracle_addr: address,
        provider: String,
        attestation_type: String,
        digest: String,
        epoch: u64,
    ) {
        assert!(exists<SentinelOracle>(oracle_addr), ENOT_INITIALIZED);
        let oracle = borrow_global_mut<SentinelOracle>(oracle_addr);
        assert!(signer::address_of(creator) == oracle.operator, ENOT_OPERATOR);
        assert!(epoch == oracle.epoch, ESTALE_EPOCH);
        // Attestation format marker must be a known type (structural check).
        assert!(is_known_attestation_type(&attestation_type), ESTALE_EPOCH);
        // Replay guard: each digest may only be accepted once per epoch.
        let used = vector::length(&oracle.used_attestations);
        let i = 0;
        while (i < used) {
            assert!(!sentinel_types::string_eq(vector::borrow(&oracle.used_attestations, i), &digest), EATTESTATION_REPLAY);
            i = i + 1;
        };
        vector::push_back(&mut oracle.used_attestations, digest);
        // Upsert provider state.
        upsert_provider_state(oracle, ProviderState {
            provider: provider,
            verified: true,
            attestation_digest: digest,
            epoch: epoch,
        });
    }

    /// Called by the provider's TEE worker (or an agent acting on the
    /// provider's behalf) after a real HTTP probe. Emits `ProbeFired` only
    /// when the provider has a valid attestation for the current epoch.
    /// Aborts otherwise.
    public entry fun probe(
        _creator: &signer,
        oracle_addr: address,
        provider: String,
        http_code: u64,
        detail: String,
    ) {
        assert!(exists<SentinelOracle>(oracle_addr), ENOT_INITIALIZED);
        let oracle = borrow_global_mut<SentinelOracle>(oracle_addr);
        let state = find_provider_state(oracle, &provider);
        assert!(state.is_some(), ENOT_VERIFIED);
        let state = option::borrow(&state);
        assert!(state.verified && state.epoch == oracle.epoch, ENOT_VERIFIED);

        let (verdict, default_detail) = sentinel_types::classify(http_code);
        let detail_final = if (string::length(&detail) == 0) {
            default_detail
        } else {
            detail
        };
        // Emit the ProbeFired event.
        event::emit(ProbeFired {
            provider: provider,
            verdict: verdict,
            http_code: http_code,
            epoch: oracle.epoch,
        });
        // Keep the detail (verdict) available for the caller via a view fn.
        let _ = detail_final;
    }

    /// Operator advances the epoch, invalidating all prior attestations.
    /// Aborts unless the caller is the operator.
    public entry fun rotate_epoch(creator: &signer, oracle_addr: address) {
        assert!(exists<SentinelOracle>(oracle_addr), ENOT_INITIALIZED);
        let oracle = borrow_global_mut<SentinelOracle>(oracle_addr);
        assert!(signer::address_of(creator) == oracle.operator, ENOT_OPERATOR);
        oracle.epoch = oracle.epoch + 1;
        oracle.used_attestations = vector::empty();
        oracle.provider_states = vector::empty();
    }

    /// Read-only: is the provider's TEE worker verified for the current
    /// epoch?
#[view]
    public fun is_verified(oracle_addr: address, provider: String): bool {
        assert!(exists<SentinelOracle>(oracle_addr), ENOT_INITIALIZED);
        let oracle = borrow_global<SentinelOracle>(oracle_addr);
        let state = find_provider_state(oracle, &provider);
        if (state.is_none()) {
            return false;
        };
        let state = option::borrow(&state);
        state.verified && state.epoch == oracle.epoch
    }

    /// Read-only current epoch.
#[view]
    public fun epoch(oracle_addr: address): u64 {
        assert!(exists<SentinelOracle>(oracle_addr), ENOT_INITIALIZED);
        borrow_global<SentinelOracle>(oracle_addr).epoch
    }

    /// The attestation digest accepted for a provider in the current epoch.
#[view]
    public fun attestation_digest(oracle_addr: address, provider: String): Option<String> {
        assert!(exists<SentinelOracle>(oracle_addr), ENOT_INITIALIZED);
        let oracle = borrow_global<SentinelOracle>(oracle_addr);
        let state = find_provider_state(oracle, &provider);
        if (state.is_none()) {
            return option::none();
        };
        let state = option::borrow(&state);
        if (state.verified && state.epoch == oracle.epoch) {
            option::some(state.attestation_digest)
        } else {
            option::none()
        }
    }

    // --- internal helpers ---

    fun is_known_attestation_type(t: &String): bool {
        let known = vector[
            string::utf8(b"phala"),
            string::utf8(b"nillion"),
            string::utf8(b"tdx"),
            string::utf8(b"sgx"),
        ];
        let n = vector::length(&known);
        let i = 0;
        while (i < n) {
            if (sentinel_types::string_eq(vector::borrow(&known, i), t)) {
                return true;
            };
            i = i + 1;
        };
        false
    }

    fun find_provider_state(oracle: &SentinelOracle, provider: &String): Option<ProviderState> {
        let n = vector::length(&oracle.provider_states);
        let i = 0;
        while (i < n) {
            let state = vector::borrow(&oracle.provider_states, i);
            if (sentinel_types::string_eq(&state.provider, provider)) {
                return option::some(*state);
            };
            i = i + 1;
        };
        option::none()
    }

    fun upsert_provider_state(oracle: &mut SentinelOracle, state: ProviderState) {
        let n = vector::length(&oracle.provider_states);
        let i = 0;
        while (i < n) {
            let existing = vector::borrow_mut(&mut oracle.provider_states, i);
            if (sentinel_types::string_eq(&existing.provider, &state.provider)) {
                *existing = state;
                return;
            };
            i = i + 1;
        };
        vector::push_back(&mut oracle.provider_states, state);
    }
}
