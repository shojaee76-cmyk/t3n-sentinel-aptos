/// sentinel_vault tests — mirror the Soroban/Starknet test suites.
#[test_only]
module sentinel::sentinel_vault_tests {
    use std::option;
    use std::string;
    use std::vector;
    use aptos_framework::account;
    use aptos_framework::timestamp;
    use sentinel::sentinel_types;
    use sentinel::sentinel_vault;

    const EABORT_NOT_AUTHORITY: u64 = 2;
    const EABORT_NOT_TEE_WORKER: u64 = 3;
    const EABORT_UNKNOWN_PROVIDER: u64 = 4;
    const EABORT_EMPTY_SECRET: u64 = 5;
    const EABORT_NOT_SEALED: u64 = 6;

    fun authority(): address { @0xaaaa }
    fun tee_worker(): address { @0xbbbb }
    fun stranger(): address { @0xcccc }

    fun vault_addr(): address { @0xcafe }

    fun setup_vault(): signer {
        timestamp::set_time_has_started_for_testing(&account::create_signer_for_test(@aptos_framework));
        timestamp::update_global_time_for_test_secs(1700000000); // make timestamp::now_seconds() work
        let vault_signer = account::create_signer_for_test(vault_addr());
        sentinel_vault::init(&vault_signer, authority(), tee_worker());
        vault_signer
    }

    #[test]
    fun init_sets_acl() {
        let _vs = setup_vault();
        let (auth, worker, count) = sentinel_vault::vault_info(vault_addr());
        assert!(auth == authority(), 0);
        assert!(worker == tee_worker(), 1);
        assert!(count == 0, 2);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = sentinel_vault)]
    fun init_twice_aborts() {
        let vs = setup_vault();
        sentinel_vault::init(&vs, authority(), tee_worker());
    }

    #[test]
    fun seal_stores_secret() {
        setup_vault();
        let auth_signer = account::create_signer_for_test(authority());
        sentinel_vault::seal(&auth_signer, vault_addr(), string::utf8(b"github"), string::utf8(b"sk-test-123"));
        let (_, _, count) = sentinel_vault::vault_info(vault_addr());
        assert!(count == 1, 0);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = sentinel_vault)]
    fun seal_unknown_provider_aborts() {
        setup_vault();
        let auth_signer = account::create_signer_for_test(authority());
        sentinel_vault::seal(&auth_signer, vault_addr(), string::utf8(b"not-a-provider"), string::utf8(b"sk"));
    }

    #[test]
    #[expected_failure(abort_code = 2, location = sentinel_vault)]
    fun seal_not_authority_aborts() {
        setup_vault();
        let stranger_signer = account::create_signer_for_test(stranger());
        sentinel_vault::seal(&stranger_signer, vault_addr(), string::utf8(b"github"), string::utf8(b"sk"));
    }

    #[test]
    #[expected_failure(abort_code = 5, location = sentinel_vault)]
    fun seal_empty_secret_aborts() {
        setup_vault();
        let auth_signer = account::create_signer_for_test(authority());
        sentinel_vault::seal(&auth_signer, vault_addr(), string::utf8(b"github"), string::utf8(b""));
    }

    #[test]
    fun record_probe_classifies_and_appends() {
        setup_vault();
        let auth_signer = account::create_signer_for_test(authority());
        sentinel_vault::seal(&auth_signer, vault_addr(), string::utf8(b"github"), string::utf8(b"sk-test-123"));
        let worker_signer = account::create_signer_for_test(tee_worker());
        sentinel_vault::record_probe(&worker_signer, vault_addr(), string::utf8(b"github"), 200, string::utf8(b""));
        let h = sentinel_vault::history(vault_addr());
        assert!(vector::length(&h) == 1, 0);
        let receipt = *vector::borrow(&h, 0);
        assert!(sentinel_types::string_eq(&sentinel_types::receipt_verdict(&receipt), &string::utf8(b"VALID")), 1);
        assert!(sentinel_types::receipt_http_code(&receipt) == 200, 2);
        assert!(sentinel_types::string_eq(&sentinel_types::receipt_detail(&receipt), &string::utf8(b"key accepted by provider")), 3);
        assert!(sentinel_types::string_eq(&sentinel_types::receipt_provider(&receipt), &string::utf8(b"github")), 4);
        assert!(sentinel_types::receipt_checked_at(&receipt) > 0, 5);
    }

    #[test]
    fun record_probe_invalid_and_rate_limited() {
        setup_vault();
        let worker_signer = account::create_signer_for_test(tee_worker());
        sentinel_vault::record_probe(&worker_signer, vault_addr(), string::utf8(b"groq"), 401, string::utf8(b""));
        sentinel_vault::record_probe(&worker_signer, vault_addr(), string::utf8(b"openrouter"), 429, string::utf8(b""));
        let h = sentinel_vault::history(vault_addr());
        assert!(vector::length(&h) == 2, 0);
        // newest first
        let newest = *vector::borrow(&h, 0);
        let oldest = *vector::borrow(&h, 1);
        assert!(sentinel_types::string_eq(&sentinel_types::receipt_provider(&newest), &string::utf8(b"openrouter")), 1);
        assert!(sentinel_types::string_eq(&sentinel_types::receipt_verdict(&newest), &string::utf8(b"RATE_LIMITED")), 2);
        assert!(sentinel_types::string_eq(&sentinel_types::receipt_provider(&oldest), &string::utf8(b"groq")), 3);
        assert!(sentinel_types::string_eq(&sentinel_types::receipt_verdict(&oldest), &string::utf8(b"INVALID")), 4);
    }

    #[test]
    fun record_probe_custom_detail_kept() {
        setup_vault();
        let worker_signer = account::create_signer_for_test(tee_worker());
        sentinel_vault::record_probe(&worker_signer, vault_addr(), string::utf8(b"github"), 500, string::utf8(b"gateway timeout"));
        let h = sentinel_vault::history(vault_addr());
        let receipt = *vector::borrow(&h, 0);
        assert!(sentinel_types::string_eq(&sentinel_types::receipt_verdict(&receipt), &string::utf8(b"UNEXPECTED")), 0);
        assert!(sentinel_types::string_eq(&sentinel_types::receipt_detail(&receipt), &string::utf8(b"gateway timeout")), 1);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = sentinel_vault)]
    fun record_probe_not_tee_worker_aborts() {
        setup_vault();
        let stranger_signer = account::create_signer_for_test(stranger());
        sentinel_vault::record_probe(&stranger_signer, vault_addr(), string::utf8(b"github"), 200, string::utf8(b""));
    }

    #[test]
    #[expected_failure(abort_code = 4, location = sentinel_vault)]
    fun record_probe_unknown_provider_aborts() {
        setup_vault();
        let worker_signer = account::create_signer_for_test(tee_worker());
        sentinel_vault::record_probe(&worker_signer, vault_addr(), string::utf8(b"nope"), 200, string::utf8(b""));
    }

    #[test]
    fun ring_buffer_caps_at_16() {
        setup_vault();
        let worker_signer = account::create_signer_for_test(tee_worker());
        let i = 0;
        while (i < 20) {
            let code = 200 + i;
            sentinel_vault::record_probe(&worker_signer, vault_addr(), string::utf8(b"github"), code, string::utf8(b""));
            i = i + 1;
        };
        let h = sentinel_vault::history(vault_addr());
        assert!(vector::length(&h) == 16, 0);
        // newest first; codes 200..219 probed, oldest kept = 204 (200-203 dropped)
        let oldest = *vector::borrow(&h, 15);
        assert!(sentinel_types::receipt_http_code(&oldest) == 204, 1);
        let newest = *vector::borrow(&h, 0);
        assert!(sentinel_types::receipt_http_code(&newest) == 219, 2);
    }

    #[test]
    fun list_providers_shows_sealed_and_verdict() {
        setup_vault();
        let auth_signer = account::create_signer_for_test(authority());
        sentinel_vault::seal(&auth_signer, vault_addr(), string::utf8(b"github"), string::utf8(b"sk-1"));
        let worker_signer = account::create_signer_for_test(tee_worker());
        sentinel_vault::record_probe(&worker_signer, vault_addr(), string::utf8(b"github"), 200, string::utf8(b""));
        let rows = sentinel_vault::list_providers(vault_addr());
        assert!(vector::length(&rows) == 4, 0);
        // github sealed + verdict
        let row0 = vector::borrow(&rows, 0);
        assert!(sentinel_types::string_eq(&sentinel_vault::row_provider(row0), &string::utf8(b"github")), 1);
        assert!(sentinel_vault::row_sealed(row0), 2);
        assert!(option::is_some(&sentinel_vault::row_last_verdict(row0)), 3);
        // groq not sealed, no verdict
        let row1 = vector::borrow(&rows, 1);
        assert!(sentinel_types::string_eq(&sentinel_vault::row_provider(row1), &string::utf8(b"groq")), 4);
        assert!(!sentinel_vault::row_sealed(row1), 5);
        assert!(option::is_none(&sentinel_vault::row_last_verdict(row1)), 6);
    }

    #[test]
    fun rotate_updates_blob() {
        setup_vault();
        let auth_signer = account::create_signer_for_test(authority());
        sentinel_vault::seal(&auth_signer, vault_addr(), string::utf8(b"github"), string::utf8(b"sk-old"));
        sentinel_vault::rotate(&auth_signer, vault_addr(), string::utf8(b"github"), string::utf8(b"sk-new"));
        let worker_signer = account::create_signer_for_test(tee_worker());
        let blob = sentinel_vault::get_secret(&worker_signer, vault_addr(), string::utf8(b"github"));
        assert!(blob == string::utf8(b"sk-new"), 0);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = sentinel_vault)]
    fun rotate_not_sealed_aborts() {
        setup_vault();
        let auth_signer = account::create_signer_for_test(authority());
        sentinel_vault::rotate(&auth_signer, vault_addr(), string::utf8(b"groq"), string::utf8(b"sk"));
    }

    #[test]
    #[expected_failure(abort_code = 3, location = sentinel_vault)]
    fun get_secret_not_tee_worker_aborts() {
        setup_vault();
        let auth_signer = account::create_signer_for_test(authority());
        sentinel_vault::seal(&auth_signer, vault_addr(), string::utf8(b"github"), string::utf8(b"sk"));
        let stranger_signer = account::create_signer_for_test(stranger());
        sentinel_vault::get_secret(&stranger_signer, vault_addr(), string::utf8(b"github"));
    }

    #[test]
    fun get_secret_returns_blob_for_worker() {
        setup_vault();
        let auth_signer = account::create_signer_for_test(authority());
        sentinel_vault::seal(&auth_signer, vault_addr(), string::utf8(b"openai"), string::utf8(b"sk-openai-xyz"));
        let worker_signer = account::create_signer_for_test(tee_worker());
        let blob = sentinel_vault::get_secret(&worker_signer, vault_addr(), string::utf8(b"openai"));
        assert!(blob == string::utf8(b"sk-openai-xyz"), 0);
    }

    #[test]
    fun vault_info_counts_sealed() {
        setup_vault();
        let auth_signer = account::create_signer_for_test(authority());
        sentinel_vault::seal(&auth_signer, vault_addr(), string::utf8(b"github"), string::utf8(b"sk-1"));
        sentinel_vault::seal(&auth_signer, vault_addr(), string::utf8(b"groq"), string::utf8(b"sk-2"));
        let (_, _, count) = sentinel_vault::vault_info(vault_addr());
        assert!(count == 2, 0);
    }
}
