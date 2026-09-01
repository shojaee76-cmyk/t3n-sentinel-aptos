/// sentinel_oracle tests — mirror the Soroban/Starknet oracle suites.
#[test_only]
module sentinel::sentinel_oracle_tests {
    use std::option;
    use std::string;
    use aptos_framework::account;
    use aptos_framework::timestamp;
    use sentinel::sentinel_oracle;
    use sentinel::sentinel_types;

    fun operator(): address { @0xdddd }
    fun worker(): address { @0xeeee }
    fun oracle_addr(): address { @0xdead }

    fun setup_oracle(): signer {
        timestamp::set_time_has_started_for_testing(&account::create_signer_for_test(@aptos_framework));
        let os = account::create_signer_for_test(oracle_addr());
        sentinel_oracle::init(&os, operator());
        os
    }

    #[test]
    fun init_sets_operator_and_epoch_zero() {
        let _os = setup_oracle();
        assert!(sentinel_oracle::epoch(oracle_addr()) == 0, 0);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = sentinel_oracle)]
    fun init_twice_aborts() {
        let os = setup_oracle();
        sentinel_oracle::init(&os, operator());
    }

    #[test]
    fun submit_attestation_verifies_provider() {
        setup_oracle();
        let op = account::create_signer_for_test(operator());
        sentinel_oracle::submit_attestation(
            &op,
            oracle_addr(),
            string::utf8(b"github"),
            string::utf8(b"tdx"),
            string::utf8(b"digest-1"),
            0,
        );
        assert!(sentinel_oracle::is_verified(oracle_addr(), string::utf8(b"github")), 0);
        let d = sentinel_oracle::attestation_digest(oracle_addr(), string::utf8(b"github"));
        assert!(option::is_some(&d), 1);
        assert!(sentinel_types::string_eq(option::borrow(&d), &string::utf8(b"digest-1")), 2);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = sentinel_oracle)]
    fun submit_not_operator_aborts() {
        setup_oracle();
        let worker_signer = account::create_signer_for_test(worker());
        sentinel_oracle::submit_attestation(
            &worker_signer,
            oracle_addr(),
            string::utf8(b"github"),
            string::utf8(b"tdx"),
            string::utf8(b"digest-1"),
            0,
        );
    }

    #[test]
    #[expected_failure(abort_code = 3, location = sentinel_oracle)]
    fun submit_stale_epoch_aborts() {
        setup_oracle();
        let op = account::create_signer_for_test(operator());
        sentinel_oracle::submit_attestation(
            &op,
            oracle_addr(),
            string::utf8(b"github"),
            string::utf8(b"tdx"),
            string::utf8(b"digest-1"),
            5, // wrong epoch
        );
    }

    #[test]
    #[expected_failure(abort_code = 4, location = sentinel_oracle)]
    fun replay_attestation_aborts() {
        setup_oracle();
        let op = account::create_signer_for_test(operator());
        sentinel_oracle::submit_attestation(
            &op,
            oracle_addr(),
            string::utf8(b"github"),
            string::utf8(b"tdx"),
            string::utf8(b"digest-1"),
            0,
        );
        sentinel_oracle::submit_attestation(
            &op,
            oracle_addr(),
            string::utf8(b"groq"),
            string::utf8(b"tdx"),
            string::utf8(b"digest-1"),
            0,
        );
    }

    #[test]
    #[expected_failure(abort_code = 3, location = sentinel_oracle)]
    fun submit_unknown_attestation_type_aborts() {
        setup_oracle();
        let op = account::create_signer_for_test(operator());
        sentinel_oracle::submit_attestation(
            &op,
            oracle_addr(),
            string::utf8(b"github"),
            string::utf8(b"quantum"),
            string::utf8(b"digest-1"),
            0,
        );
    }

    #[test]
    fun probe_emits_event_for_verified_provider() {
        setup_oracle();
        let op = account::create_signer_for_test(operator());
        sentinel_oracle::submit_attestation(
            &op,
            oracle_addr(),
            string::utf8(b"github"),
            string::utf8(b"phala"),
            string::utf8(b"digest-1"),
            0,
        );
        let worker_signer = account::create_signer_for_test(worker());
        // Should not abort — the provider is verified for the current epoch.
        sentinel_oracle::probe(&worker_signer, oracle_addr(), string::utf8(b"github"), 200, string::utf8(b""));
        assert!(sentinel_oracle::is_verified(oracle_addr(), string::utf8(b"github")), 0);
    }

    #[test]
    #[expected_failure(abort_code = 5, location = sentinel_oracle)]
    fun probe_not_verified_aborts() {
        setup_oracle();
        let worker_signer = account::create_signer_for_test(worker());
        sentinel_oracle::probe(&worker_signer, oracle_addr(), string::utf8(b"github"), 200, string::utf8(b""));
    }

    #[test]
    fun rotate_epoch_invalidates_attestations() {
        setup_oracle();
        let op = account::create_signer_for_test(operator());
        sentinel_oracle::submit_attestation(
            &op,
            oracle_addr(),
            string::utf8(b"github"),
            string::utf8(b"tdx"),
            string::utf8(b"digest-1"),
            0,
        );
        assert!(sentinel_oracle::is_verified(oracle_addr(), string::utf8(b"github")), 0);
        sentinel_oracle::rotate_epoch(&op, oracle_addr());
        assert!(sentinel_oracle::epoch(oracle_addr()) == 1, 0);
        assert!(!sentinel_oracle::is_verified(oracle_addr(), string::utf8(b"github")), 1);
        // New attestation in new epoch works.
        sentinel_oracle::submit_attestation(
            &op,
            oracle_addr(),
            string::utf8(b"github"),
            string::utf8(b"tdx"),
            string::utf8(b"digest-2"),
            1,
        );
        assert!(sentinel_oracle::is_verified(oracle_addr(), string::utf8(b"github")), 2);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = sentinel_oracle)]
    fun rotate_epoch_not_operator_aborts() {
        setup_oracle();
        let worker_signer = account::create_signer_for_test(worker());
        sentinel_oracle::rotate_epoch(&worker_signer, oracle_addr());
    }

    #[test]
    fun is_verified_false_for_unverified() {
        setup_oracle();
        assert!(!sentinel_oracle::is_verified(oracle_addr(), string::utf8(b"groq")), 0);
    }

    #[test]
    fun attestation_digest_none_when_unverified() {
        setup_oracle();
        let d = sentinel_oracle::attestation_digest(oracle_addr(), string::utf8(b"groq"));
        assert!(option::is_none(&d), 0);
    }
}
