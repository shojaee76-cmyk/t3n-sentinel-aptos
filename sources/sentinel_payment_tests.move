/// sentinel_payment tests — mirror the Soroban payment suite.
#[test_only]
module sentinel::sentinel_payment_tests {
    use std::option;
    use std::string;
    use std::vector;
    use aptos_framework::account;
    use aptos_framework::aptos_coin;
    use aptos_framework::coin;
    use aptos_framework::primary_fungible_store;
    use aptos_framework::timestamp;
    use sentinel::sentinel_payment;

    const EABORT_NOT_AUTHORITY: u64 = 2;
    const EABORT_NOT_TEE_WORKER: u64 = 3;
    const EABORT_UNKNOWN_PROVIDER: u64 = 4;
    const EABORT_PAYMENT_MISMATCH: u64 = 6;
    const EABORT_PAYWALL_REQUIRED: u64 = 7;

    fun authority(): address { @0xaaaa }
    fun tee_worker(): address { @0xbbbb }
    fun payout(): address { @0xdddd }
    fun stranger(): address { @0xcccc }
    fun rail_addr(): address { @0xbeef }

    fun setup_rail(): signer {
        timestamp::set_time_has_started_for_testing(&account::create_signer_for_test(@aptos_framework));
        timestamp::update_global_time_for_test_secs(1700000000);
        let rs = account::create_signer_for_test(rail_addr());
        sentinel_payment::init(&rs, authority(), tee_worker());
        rs
    }

    #[test]
    fun init_sets_acl() {
        let _rs = setup_rail();
        let cfg = sentinel_payment::provider_config(rail_addr(), string::utf8(b"github"));
        assert!(option::is_none(&cfg), 1);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = sentinel_payment)]
    fun init_twice_aborts() {
        let rs = setup_rail();
        sentinel_payment::init(&rs, authority(), tee_worker());
    }

    #[test]
    fun configure_provider_sets_payout_and_price() {
        setup_rail();
        let auth = account::create_signer_for_test(authority());
        sentinel_payment::configure_provider(&auth, rail_addr(), string::utf8(b"github"), payout(), 100, true);
        let cfg = sentinel_payment::provider_config(rail_addr(), string::utf8(b"github"));
        assert!(option::is_some(&cfg), 0);
        let c = option::borrow(&cfg);
        assert!(sentinel_payment::config_payout(c) == payout(), 1);
        assert!(sentinel_payment::config_price(c) == 100, 2);
        assert!(sentinel_payment::config_paywalled(c), 3);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = sentinel_payment)]
    fun configure_not_authority_aborts() {
        setup_rail();
        let stranger_signer = account::create_signer_for_test(stranger());
        sentinel_payment::configure_provider(&stranger_signer, rail_addr(), string::utf8(b"github"), payout(), 10, true);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = sentinel_payment)]
    fun configure_unknown_provider_aborts() {
        setup_rail();
        let auth = account::create_signer_for_test(authority());
        sentinel_payment::configure_provider(&auth, rail_addr(), string::utf8(b"nope"), payout(), 10, true);
    }

    #[test]
    fun free_probe_no_payment_needed() {
        setup_rail();
        let auth = account::create_signer_for_test(authority());
        sentinel_payment::configure_provider(&auth, rail_addr(), string::utf8(b"github"), payout(), 0, false);
        let worker = account::create_signer_for_test(tee_worker());
        sentinel_payment::probe_with_payment(&worker, rail_addr(), string::utf8(b"github"), 200, string::utf8(b""), 0);
        let h = sentinel_payment::history(rail_addr());
        assert!(vector::length(&h) == 1, 0);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = sentinel_payment)]
    fun paywalled_probe_without_payment_aborts() {
        setup_rail();
        let auth = account::create_signer_for_test(authority());
        sentinel_payment::configure_provider(&auth, rail_addr(), string::utf8(b"github"), payout(), 100, true);
        let worker = account::create_signer_for_test(tee_worker());
        // paid=0 while price=100 → paywalled requires payment.
        sentinel_payment::probe_with_payment(&worker, rail_addr(), string::utf8(b"github"), 200, string::utf8(b""), 0);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = sentinel_payment)]
    fun paywalled_probe_wrong_amount_aborts() {
        setup_rail();
        let auth = account::create_signer_for_test(authority());
        sentinel_payment::configure_provider(&auth, rail_addr(), string::utf8(b"github"), payout(), 100, true);
        let worker = account::create_signer_for_test(tee_worker());
        // paid=50 while price=100 → mismatch.
        sentinel_payment::probe_with_payment(&worker, rail_addr(), string::utf8(b"github"), 200, string::utf8(b""), 50);
    }

    #[test]
    fun paywalled_probe_with_exact_payment_succeeds() {
        setup_rail();
        let auth = account::create_signer_for_test(authority());
        sentinel_payment::configure_provider(&auth, rail_addr(), string::utf8(b"github"), payout(), 100, true);
        // Fund the WORKER (the payer) with APT using the framework's test mint.
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&account::create_signer_for_test(@aptos_framework));
        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
        let fa = aptos_coin::mint_apt_fa_for_test(1000);
        primary_fungible_store::deposit(tee_worker(), fa);
        // Worker pays exact price.
        let worker = account::create_signer_for_test(tee_worker());
        sentinel_payment::probe_with_payment(&worker, rail_addr(), string::utf8(b"github"), 200, string::utf8(b""), 100);
        // Receipt appended.
        let h = sentinel_payment::history(rail_addr());
        assert!(vector::length(&h) == 1, 0);
        let bal = sentinel_payment::vault_balance(tee_worker());
        assert!(bal == 900, 1);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = sentinel_payment)]
    fun probe_not_tee_worker_aborts() {
        setup_rail();
        let auth = account::create_signer_for_test(authority());
        sentinel_payment::configure_provider(&auth, rail_addr(), string::utf8(b"github"), payout(), 0, false);
        let stranger_signer = account::create_signer_for_test(stranger());
        sentinel_payment::probe_with_payment(&stranger_signer, rail_addr(), string::utf8(b"github"), 200, string::utf8(b""), 0);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = sentinel_payment)]
    fun probe_unknown_provider_aborts() {
        setup_rail();
        let worker = account::create_signer_for_test(tee_worker());
        sentinel_payment::probe_with_payment(&worker, rail_addr(), string::utf8(b"nope"), 200, string::utf8(b""), 0);
    }
}
