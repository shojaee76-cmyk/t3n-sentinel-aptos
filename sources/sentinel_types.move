/// sentinel_types — shared types, classifier and provider registry for the
/// Aptos Move port of t3n-sentinel.
///
/// Mirrors the classifier from the T3N WASM contract and the Solana/Starknet/
/// Soroban ports: an HTTP status maps to a verdict in
/// {VALID, INVALID, RATE_LIMITED, UNEXPECTED} plus a default human-readable
/// detail. The provider registry is the single maintenance point — adding a
/// new provider = appending one string here (same maintenance contract as the
/// other four ports).
module sentinel::sentinel_types {
    use std::string::{Self, String};
    use std::vector;

    /// Canonical probe outcome — same shape as the T3N Verdict / Solana
    /// ProbeReceipt / Starknet ProbeReceipt / Soroban ProbeReceipt.
    struct ProbeReceipt has store, copy, drop {
        provider: String,
        /// VALID | INVALID | RATE_LIMITED | UNEXPECTED
        verdict: String,
        http_code: u64,
        detail: String,
        checked_at: u64,
    }

    /// Known providers. Endpoints are informational registry data (the actual
    /// HTTP probing happens inside the TEE worker off-chain).
    public fun provider_names(): vector<String> {
        vector[
            string::utf8(b"github"),
            string::utf8(b"groq"),
            string::utf8(b"openrouter"),
            string::utf8(b"openai"),
        ]
    }

    /// Is this provider in the registry?
    public fun is_known_provider(provider: &String): bool {
        let names = provider_names();
        let n = vector::length(&names);
        let i = 0;
        while (i < n) {
            if (string::bytes(vector::borrow(&names, i)) == string::bytes(provider)) {
                return true;
            };
            i = i + 1;
        };
        false
    }

    /// Structural equality for Strings (the stdlib has no `string::equal`).
    public fun string_eq(a: &String, b: &String): bool {
        string::bytes(a) == string::bytes(b)
    }

    /// Getter: provider of a receipt.
    public fun receipt_provider(r: &ProbeReceipt): String {
        r.provider
    }

    /// Getter: verdict of a receipt.
    public fun receipt_verdict(r: &ProbeReceipt): String {
        r.verdict
    }

    /// Getter: http_code of a receipt.
    public fun receipt_http_code(r: &ProbeReceipt): u64 {
        r.http_code
    }

    /// Getter: detail of a receipt.
    public fun receipt_detail(r: &ProbeReceipt): String {
        r.detail
    }

    /// Getter: checked_at of a receipt.
    public fun receipt_checked_at(r: &ProbeReceipt): u64 {
        r.checked_at
    }

    /// Constructor: build a ProbeReceipt (struct is module-private, so
    /// construction goes through here).
    public fun new_receipt(
        provider: String,
        verdict: String,
        http_code: u64,
        detail: String,
        checked_at: u64,
    ): ProbeReceipt {
        ProbeReceipt {
            provider,
            verdict,
            http_code,
            detail,
            checked_at,
        }
    }

    /// Map an HTTP status to a verdict. Same shape as the other ports.
    /// Returns (verdict, default_detail).
    public fun classify(code: u64): (String, String) {
        if (code >= 200 && code <= 299) {
            (string::utf8(b"VALID"), string::utf8(b"key accepted by provider"))
        } else if (code == 401 || code == 403) {
            (string::utf8(b"INVALID"), string::utf8(b"credentials rejected by provider"))
        } else if (code == 429) {
            (string::utf8(b"RATE_LIMITED"), string::utf8(b"quota exhausted"))
        } else {
            (string::utf8(b"UNEXPECTED"), string::utf8(b"unclassified status code"))
        }
    }
}
