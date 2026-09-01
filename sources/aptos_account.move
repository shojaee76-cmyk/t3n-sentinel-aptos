/// Minimal signer helpers for tests and the on-chain demo flow.
///
/// In tests we use `account::create_signer_for_test` (a #[test_only] framework
/// helper) to mint signers for arbitrary addresses. This module exposes a
/// thin, non-test-only wrapper so the deployment scripts and integration
/// helpers share one entry point. It is intentionally tiny — it only needs
/// `aptos_framework::account` (available as a dependency, no framework friends).
module sentinel::aptos_account {
    use aptos_framework::account;

    /// True if `addr` has an Aptos `Account` resource.
    public fun account_exists(addr: address): bool {
        account::exists_at(addr)
    }
}
