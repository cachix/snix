use crate::nixbase32;
use bstr::ByteSlice;
use data_encoding::{BASE64, BASE64_NOPAD, HEXLOWER};
use std::cmp::Ordering;
use std::fmt::Display;
use thiserror;

mod algos;
mod ca_hash;
#[cfg(feature = "serde")]
pub mod serde;

pub use algos::HashAlgo;
pub use ca_hash::CAHash;
pub use ca_hash::HashMode as CAHashMode;

/// NixHash represents hashes known by Nix (md5/sha1/sha256/sha512).
///
/// Internally, these are represented as an enum of 4 kinds (the latter being
/// boxed for size reasons, as we rarely use sha512, having a pointer there
/// is fine).
///
/// There's [Self::algo] and [Self::digest_as_bytes] accessors,
/// as well as a [Self::from_algo_and_digest] constructor.
///
/// A few methods to parse (`from_$format_$encoding`) and emit
/// (`to_$format_$encoding`) various formats and encodings Nix uses.
///
/// # Formats
/// The following formats exist:
///
/// ## Nix Format
/// Lowercase algo, followed by a colon, then the digest.
///
/// ## SRI Format
/// Uses the lowercase algo, followed by a `-`, then the digest (base64-encoded).
/// This is also used in the Display implementation.
///
/// Contrary to the SRI spec, Nix doesn't have an understanding of passing
/// multiple hashes (with different algos) in SRI hashes.
/// It instead simply cuts everything off after the expected length for the
/// specified algo, and tries to parse the rest in permissive base64 (allowing
/// missing padding).
///
/// ## Digest only
/// It's possible to not specify the algo at all. In that case, the expected
/// NixHash algo MUST be provided externally.
///
/// # Encodings
/// For "Nix" and "Digest only" formats, the following encodings are supported:
///
/// - lowerhex,
/// - nixbase32,
/// - base64 (StdEncoding)
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum NixHash {
    Md5([u8; 16]),
    Sha1([u8; 20]),
    Sha256([u8; 32]),
    Sha512(Box<[u8; 64]>),
}

/// Same order as sorting the corresponding nixbase32 strings.
///
/// This order is used in the ATerm serialization of a derivation
/// and thus affects the calculated output hash.
impl Ord for NixHash {
    fn cmp(&self, other: &NixHash) -> Ordering {
        self.digest_as_bytes().cmp(other.digest_as_bytes())
    }
}

// See Ord for reason to implement this manually.
impl PartialOrd for NixHash {
    fn partial_cmp(&self, other: &NixHash) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

// This provides a Display impl, which happens to be SRI right now.
// If you explicitly care about the format, use [NixHash::to_sri_string]
// or [NixHash::write_sri_str].
impl Display for NixHash {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::result::Result<(), std::fmt::Error> {
        self.write_sri_str(f)
    }
}

impl NixHash {
    /// returns the algo as [HashAlgo].
    pub fn algo(&self) -> HashAlgo {
        match self {
            NixHash::Md5(_) => HashAlgo::Md5,
            NixHash::Sha1(_) => HashAlgo::Sha1,
            NixHash::Sha256(_) => HashAlgo::Sha256,
            NixHash::Sha512(_) => HashAlgo::Sha512,
        }
    }

    /// returns the digest as variable-length byte slice.
    pub fn digest_as_bytes(&self) -> &[u8] {
        match self {
            NixHash::Md5(digest) => digest,
            NixHash::Sha1(digest) => digest,
            NixHash::Sha256(digest) => digest,
            NixHash::Sha512(digest) => digest.as_ref(),
        }
    }

    /// Constructs a new [NixHash] by specifying [HashAlgo] and digest.
    /// It can fail if the passed digest length doesn't match what's expected for
    /// the passed algo.
    pub fn from_algo_and_digest(algo: HashAlgo, digest: &[u8]) -> Result<NixHash, Error> {
        if digest.len() != algo.digest_length() {
            return Err(Error::InvalidDigestLength(algo));
        }

        Ok(match algo {
            HashAlgo::Md5 => NixHash::Md5(digest.try_into().unwrap()),
            HashAlgo::Sha1 => NixHash::Sha1(digest.try_into().unwrap()),
            HashAlgo::Sha256 => NixHash::Sha256(digest.try_into().unwrap()),
            HashAlgo::Sha512 => NixHash::Sha512(Box::new(digest.try_into().unwrap())),
        })
    }

    /// Constructs a new [NixHash] from the Nix default hash format,
    /// the inverse of [Self::to_nix_nixbase32].
    pub fn from_nix_nixbase32(s: &str) -> Option<Self> {
        let (tag, digest) = s.split_once(':')?;

        (match tag {
            "md5" => nixbase32::decode_fixed(digest).map(NixHash::Md5),
            "sha1" => nixbase32::decode_fixed(digest).map(NixHash::Sha1),
            "sha256" => nixbase32::decode_fixed(digest).map(NixHash::Sha256),
            "sha512" => nixbase32::decode_fixed(digest)
                .map(Box::new)
                .map(NixHash::Sha512),
            _ => return None,
        })
        .ok()
    }

    /// Formats a [NixHash] in the Nix nixbase32 format.
    pub fn to_nix_nixbase32(&self) -> String {
        format!(
            "{}:{}",
            self.algo(),
            nixbase32::encode(self.digest_as_bytes())
        )
    }

    /// Parses a Nix SRI string to a NixHash.
    /// (See caveats in [Self] on the deviations from the SRI spec)
    pub fn from_sri(s: &str) -> Result<NixHash, Error> {
        // split at the first occurence of "-"
        let (algo_str, digest_str) = s.split_once('-').ok_or(Error::InvalidSRI)?;

        // try to map the part before that `-` to a supported hash algo:
        let algo: HashAlgo = algo_str.try_into()?;

        // For the digest string, Nix ignores everything after the expected BASE64
        // (with padding) length, to account for the fact SRI allows specifying more
        // than one checksum, so shorten it.
        let digest_str = {
            let encoded_max_len = BASE64.encode_len(algo.digest_length());
            if digest_str.len() > encoded_max_len {
                &digest_str.as_bytes()[..encoded_max_len]
            } else {
                digest_str.as_bytes()
            }
        };

        // if the digest string is too small to fit even the BASE64_NOPAD version, bail out.
        if digest_str.len() < BASE64_NOPAD.encode_len(algo.digest_length()) {
            return Err(Error::InvalidDigestLength(algo));
        }

        // trim potential padding, and use a version that does not do trailing bit
        // checking.
        let mut spec = BASE64_NOPAD.specification();
        spec.check_trailing_bits = false;
        let encoding = spec
            .encoding()
            .expect("Snix bug: failed to get the special base64 encoder for Nix SRI hashes");

        let digest = encoding
            .decode(digest_str.trim_end_with(|c| c == '='))
            .map_err(Error::InvalidBase64Encoding)?;

        Self::from_algo_and_digest(algo, &digest)
    }

    /// Writes a [NixHash] in SRI format to a [std::fmt::Write].
    pub fn write_sri_str(&self, w: &mut impl std::fmt::Write) -> Result<(), std::fmt::Error> {
        write!(
            w,
            "{}-{}",
            self.algo(),
            BASE64.encode(self.digest_as_bytes())
        )
    }

    /// Formats a [NixHash] to an SRI string.
    pub fn to_sri_string(&self) -> String {
        let mut s = String::new();
        self.write_sri_str(&mut s).unwrap();

        s
    }

    /// Formats a [NixHash] in the Nix lowerhex format.
    pub fn to_nix_lowerhex_string(&self) -> String {
        format!(
            "{}:{}",
            self.algo(),
            HEXLOWER.encode(self.digest_as_bytes())
        )
    }

    /// This parses all known output formats for NixHash.
    /// See [NixHash] for a list.
    /// An optional algo needs to be provided, which is mandatory to be specified if
    /// the "digest only" format is used.
    /// In other cases, consistency of an optionally externally configured algo
    /// with the one parsed is ensured.
    pub fn from_str(s: &str, want_algo: Option<HashAlgo>) -> Result<NixHash, Error> {
        // Check for SRI hashes.
        if let Ok(parsed_nixhash) = Self::from_sri(s) {
            // ensure the algo matches with what has been passed externally, if so.
            if let Some(algo) = want_algo {
                if algo != parsed_nixhash.algo() {
                    return Err(Error::ConflictingHashAlgos(algo, parsed_nixhash.algo()));
                }
            }
            return Ok(parsed_nixhash);
        }

        // Check for $algo:$digest style NixHash.
        if let Some(parsed_nixhash) = {
            if let Some(rest) = s.strip_prefix("sha1:") {
                Some(decode_digest(rest.as_bytes(), HashAlgo::Sha1)?)
            } else if let Some(rest) = s.strip_prefix("sha256:") {
                Some(decode_digest(rest.as_bytes(), HashAlgo::Sha256)?)
            } else if let Some(rest) = s.strip_prefix("sha512:") {
                Some(decode_digest(rest.as_bytes(), HashAlgo::Sha512)?)
            } else if let Some(rest) = s.strip_prefix("md5:") {
                Some(decode_digest(rest.as_bytes(), HashAlgo::Md5)?)
            } else {
                None
            }
        } {
            // ensure the algo matches with what has been passed externally, if so.
            if let Some(algo) = want_algo {
                if algo != parsed_nixhash.algo() {
                    return Err(Error::ConflictingHashAlgos(algo, parsed_nixhash.algo()));
                }
            }

            return Ok(parsed_nixhash);
        }

        // We're left with the bare digest case, so there MUST be an externally-passed algo.
        let algo = want_algo.ok_or_else(|| Error::MissingInlineHashAlgo(s.to_string()))?;
        decode_digest(s.as_bytes(), algo)
    }
}

/// Errors related to NixHash construction.
#[derive(Debug, Eq, PartialEq, thiserror::Error)]
pub enum Error {
    #[error("invalid hash algo")]
    InvalidAlgo,
    #[error("invalid SRI string")]
    InvalidSRI,
    #[error("invalid digest length for algo {0}")]
    InvalidDigestLength(HashAlgo),
    #[error("invalid base16 encoding: {0}")]
    InvalidBase16Encoding(data_encoding::DecodeError),
    #[error("invalid base32 encoding: {0}")]
    InvalidBase32Encoding(data_encoding::DecodeError),
    #[error("invalid base64 encoding: {0}")]
    InvalidBase64Encoding(data_encoding::DecodeError),
    #[error("conflicting hash algo: {0} (hash_algo) vs {1} (inline)")]
    ConflictingHashAlgos(HashAlgo, HashAlgo),
    #[error("missing inline hash algo, but no externally-specified algo: {0:?}")]
    MissingInlineHashAlgo(String),
}

/// Decode a plain digest depending on the hash algo specified externally.
/// hexlower, nixbase32 and base64 encodings are supported - the encoding is
/// inferred from the input length.
fn decode_digest(s: &[u8], algo: HashAlgo) -> Result<NixHash, Error> {
    // for the chosen hash algo, calculate the expected (decoded) digest length
    // (as bytes)
    let digest = if s.len() == HEXLOWER.encode_len(algo.digest_length()) {
        HEXLOWER
            .decode(s.as_ref())
            .map_err(Error::InvalidBase16Encoding)?
    } else if s.len() == nixbase32::encode_len(algo.digest_length()) {
        nixbase32::decode(s).map_err(Error::InvalidBase32Encoding)?
    } else if s.len() == BASE64.encode_len(algo.digest_length()) {
        BASE64
            .decode(s.as_ref())
            .map_err(Error::InvalidBase64Encoding)?
    } else {
        Err(Error::InvalidDigestLength(algo))?
    };

    Ok(NixHash::from_algo_and_digest(algo, &digest).unwrap())
}

#[cfg(test)]
mod tests {
    use crate::nixhash::{HashAlgo, NixHash};
    use hex_literal::hex;
    use rstest::rstest;
    use std::sync::LazyLock;

    const NIXHASH_SHA1: NixHash = NixHash::Sha1(hex!("6016777997c30ab02413cf5095622cd7924283ac"));
    const NIXHASH_SHA256: NixHash = NixHash::Sha256(hex!(
        "a5ce9c155ed09397614646c9717fc7cd94b1023d7b76b618d409e4fefd6e9d39"
    ));
    static NIXHASH_SHA512: LazyLock<NixHash> = LazyLock::new(|| {
        NixHash::Sha512(Box::new(hex!(
            "ab40d0be3541f0774bba7815d13d10b03252e96e95f7dbb4ee99a3b431c21662fd6971a020160e39848aa5f305b9be0f78727b2b0789e39f124d21e92b8f39ef"
        )))
    });
    const NIXHASH_MD5: NixHash = NixHash::Md5(hex!("c4874a8897440b393d862d8fd459073f"));

    /// Test parsing a hash string in various formats, and also when/how the out-of-band algo is needed.
    #[rstest]
    // regular SRI hashes. We test some funny encoding edge cases in a separate test.
    #[case::sri_sha1("sha1-YBZ3eZfDCrAkE89QlWIs15JCg6w=", HashAlgo::Sha1, NIXHASH_SHA1)]
    #[case::sri_sha256(
        "sha256-pc6cFV7Qk5dhRkbJcX/HzZSxAj17drYY1Ank/v1unTk=",
        HashAlgo::Sha256,
        NIXHASH_SHA256
    )]
    #[case::sri_sha512(
        "sha512-q0DQvjVB8HdLungV0T0QsDJS6W6V99u07pmjtDHCFmL9aXGgIBYOOYSKpfMFub4PeHJ7KweJ458STSHpK4857w==",
        HashAlgo::Sha512,
        (*NIXHASH_SHA512).clone()
    )]
    // lowerhex
    #[case::lowerhex_sha1(
        "sha1:6016777997c30ab02413cf5095622cd7924283ac",
        HashAlgo::Sha1,
        NIXHASH_SHA1
    )]
    #[case::lowerhex_sha256(
        "sha256:a5ce9c155ed09397614646c9717fc7cd94b1023d7b76b618d409e4fefd6e9d39",
        HashAlgo::Sha256,
        NIXHASH_SHA256
    )]
    #[case::lowerhex_sha512("sha512:ab40d0be3541f0774bba7815d13d10b03252e96e95f7dbb4ee99a3b431c21662fd6971a020160e39848aa5f305b9be0f78727b2b0789e39f124d21e92b8f39ef", HashAlgo::Sha512, (*NIXHASH_SHA512).clone())]
    #[case::lowerhex_md5("md5:c4874a8897440b393d862d8fd459073f", HashAlgo::Md5, NIXHASH_MD5)]
    #[case::lowerhex_md5("md5-xIdKiJdECzk9hi2P1FkHPw==", HashAlgo::Md5, NIXHASH_MD5)]
    // base64
    #[case::base64_sha1("sha1:YBZ3eZfDCrAkE89QlWIs15JCg6w=", HashAlgo::Sha1, NIXHASH_SHA1)]
    #[case::base64_sha256(
        "sha256:pc6cFV7Qk5dhRkbJcX/HzZSxAj17drYY1Ank/v1unTk=",
        HashAlgo::Sha256,
        NIXHASH_SHA256
    )]
    #[case::base64_sha512("sha512:q0DQvjVB8HdLungV0T0QsDJS6W6V99u07pmjtDHCFmL9aXGgIBYOOYSKpfMFub4PeHJ7KweJ458STSHpK4857w==", HashAlgo::Sha512, (*NIXHASH_SHA512).clone())]
    #[case::base64_md5("md5:xIdKiJdECzk9hi2P1FkHPw==", HashAlgo::Md5, NIXHASH_MD5)]
    // nixbase32
    #[case::nixbase32_sha1("sha1:mj1l54np5ii9al6g2cjb02n3jxwpf5k0", HashAlgo::Sha1, NIXHASH_SHA1)]
    #[case::nixbase32_sha256(
        "sha256:0fcxdvyzxr09shcbcxkv7l1b356dqxzp3ja68rhrg4yhbqarrkm5",
        HashAlgo::Sha256,
        NIXHASH_SHA256
    )]
    #[case::nixbase32_sha512("sha512:3pkk3rbx4hls4lzwf4hfavvf9w0zgmr0prsb2l47471c850f5lzsqhnq8qv98wrxssdpxwmdvlm4cmh20yx25bqp95pgw216nzd0h5b", HashAlgo::Sha512, (*NIXHASH_SHA512).clone())]
    #[case::nixbase32_md5("md5:1z0xcx93rdhqykj2s4jy44m1y4", HashAlgo::Md5, NIXHASH_MD5)]
    fn from_str(#[case] s: &str, #[case] algo: HashAlgo, #[case] expected: NixHash) {
        assert_eq!(
            expected,
            NixHash::from_str(s, Some(algo)).expect("must parse"),
            "should parse"
        );

        // We expect all s to contain an algo in-band, so expect it to parse without an algo too.
        assert_eq!(
            expected,
            NixHash::from_str(s, None).expect("must parse without algo too"),
            "should parse"
        );

        // Whenever we encounter a hash with a `$algo:` prefix, we pop that prefix
        // and test it parses without it if the algo is passed in externally, but fails if not.
        // We do this for a subset of inputs here in the testcase, rather than adding 12 new testcases (4 algos x 3 encodings)
        if let Some(digest_str) = s
            .strip_prefix("sha1:")
            .or(s.strip_prefix("sha256:"))
            .or(s.strip_prefix("sha512:"))
            .or(s.strip_prefix("sha512:"))
        {
            assert_eq!(
                expected,
                NixHash::from_str(digest_str, Some(algo))
                    .expect("must parse digest-only if algo specified")
            );
            NixHash::from_str(digest_str, None)
                .expect_err("must fail parsing digest-only if algo not specified");
        }
    }

    // Test parsing a hash specifying another algo than what's passed externally fails.
    #[test]
    fn test_want_algo() {
        NixHash::from_str("sha1-YBZ3eZfDCrAkE89QlWIs15JCg6w=", Some(HashAlgo::Md5))
            .expect_err("parsing with conflicting want_algo should fail");

        NixHash::from_str("sha1:YBZ3eZfDCrAkE89QlWIs15JCg6w=", Some(HashAlgo::Md5))
            .expect_err("parsing with conflicting want_algo should fail");
    }

    /// Test parsing an SRI hash via the [nixhash::from_sri_str] method.
    #[test]
    fn from_sri_str() {
        let nix_hash = NixHash::from_sri("sha256-pc6cFV7Qk5dhRkbJcX/HzZSxAj17drYY1Ank/v1unTk=")
            .expect("must succeed");

        assert_eq!(HashAlgo::Sha256, nix_hash.algo());
        assert_eq!(
            &hex!("a5ce9c155ed09397614646c9717fc7cd94b1023d7b76b618d409e4fefd6e9d39"),
            nix_hash.digest_as_bytes()
        )
    }

    /// Test parsing sha512 SRI hash with various paddings, Nix accepts all of them.
    #[rstest]
    #[case::no_padding(
        "sha512-7g91TBvYoYQorRTqo+rYD/i5YnWvUBLnqDhPHxBJDaBW7smuPMeRp6E6JOFuVN9bzN0QnH1ToUU0u9c2CjALEQ"
    )]
    #[case::too_little_padding(
        "sha512-7g91TBvYoYQorRTqo+rYD/i5YnWvUBLnqDhPHxBJDaBW7smuPMeRp6E6JOFuVN9bzN0QnH1ToUU0u9c2CjALEQ="
    )]
    #[case::correct_padding(
        "sha512-7g91TBvYoYQorRTqo+rYD/i5YnWvUBLnqDhPHxBJDaBW7smuPMeRp6E6JOFuVN9bzN0QnH1ToUU0u9c2CjALEQ=="
    )]
    #[case::too_much_padding(
        "sha512-7g91TBvYoYQorRTqo+rYD/i5YnWvUBLnqDhPHxBJDaBW7smuPMeRp6E6JOFuVN9bzN0QnH1ToUU0u9c2CjALEQ==="
    )]
    #[case::additional_suffix_ignored(
        "sha512-7g91TBvYoYQorRTqo+rYD/i5YnWvUBLnqDhPHxBJDaBW7smuPMeRp6E6JOFuVN9bzN0QnH1ToUU0u9c2CjALEQ== cheesecake"
    )]
    fn from_sri_str_sha512_paddings(#[case] sri_str: &str) {
        let nix_hash = NixHash::from_sri(sri_str).expect("must succeed");

        assert_eq!(HashAlgo::Sha512, nix_hash.algo());
        assert_eq!(
            &hex!(
                "ee0f754c1bd8a18428ad14eaa3ead80ff8b96275af5012e7a8384f1f10490da056eec9ae3cc791a7a13a24e16e54df5bccdd109c7d53a14534bbd7360a300b11"
            ),
            nix_hash.digest_as_bytes()
        )
    }

    /// Ensure we detect truncated base64 digests, where the digest size
    /// doesn't match what's expected from that hash function.
    #[test]
    fn from_sri_str_truncated() {
        NixHash::from_sri("sha256-pc6cFV7Qk5dhRkbJcX/HzZSxAj17drYY1Ank").expect_err("must fail");
    }

    /// Ensure we fail on SRI hashes that Nix doesn't support.
    #[test]
    fn from_sri_str_unsupported() {
        NixHash::from_sri(
            "sha384-o4UVSl89mIB0sFUK+3jQbG+C9Zc9dRlV/Xd3KAvXEbhqxu0J5OAdg6b6VHKHwQ7U",
        )
        .expect_err("must fail");
    }

    /// Ensure we reject invalid base64 encoding
    #[test]
    fn from_sri_str_invalid_base64() {
        NixHash::from_sri("sha256-invalid=base64").expect_err("must fail");
    }

    /// Nix also accepts SRI strings with missing padding, but only in case the
    /// string is expressed as SRI, so it still needs to have a `sha256-` prefix.
    ///
    /// This both seems to work if it is passed with and without specifying the
    /// hash algo out-of-band (hash = "sha256-…" or sha256 = "sha256-…")
    ///
    /// Passing the same broken base64 string, but not as SRI, while passing
    /// the hash algo out-of-band does not work.
    #[test]
    fn sha256_broken_padding() {
        let broken_base64 = "fgIr3TyFGDAXP5+qoAaiMKDg/a1MlT6Fv/S/DaA24S8";
        // if padded with a trailing '='
        let expected_digest =
            hex!("7e022bdd3c851830173f9faaa006a230a0e0fdad4c953e85bff4bf0da036e12f");

        // passing hash algo out of band should succeed
        let nix_hash = NixHash::from_str(
            &format!("sha256-{}", &broken_base64),
            Some(HashAlgo::Sha256),
        )
        .expect("must succeed");
        assert_eq!(&expected_digest, &nix_hash.digest_as_bytes());

        // not passing hash algo out of band should succeed
        let nix_hash =
            NixHash::from_str(&format!("sha256-{}", &broken_base64), None).expect("must succeed");
        assert_eq!(&expected_digest, &nix_hash.digest_as_bytes());

        // not passing SRI, but hash algo out of band should fail
        NixHash::from_str(broken_base64, Some(HashAlgo::Sha256)).expect_err("must fail");
    }

    /// As we decided to pass our hashes by trimming `=` completely,
    /// we need to take into account hashes with padding requirements which
    /// contains trailing bits which would be checked by `BASE64_NOPAD` and would
    /// make the verification crash.
    ///
    /// This base64 has a trailing non-zero bit at bit 42.
    #[test]
    fn sha256_weird_base64() {
        let weird_base64 = "syceJMUEknBDCHK8eGs6rUU3IQn+HnQfURfCrDxYPa9=";
        let expected_digest =
            hex!("b3271e24c5049270430872bc786b3aad45372109fe1e741f5117c2ac3c583daf");

        let nix_hash =
            NixHash::from_str(&format!("sha256-{}", &weird_base64), Some(HashAlgo::Sha256))
                .expect("must succeed");
        assert_eq!(&expected_digest, &nix_hash.digest_as_bytes());

        // not passing hash algo out of band should succeed
        let nix_hash =
            NixHash::from_str(&format!("sha256-{}", &weird_base64), None).expect("must succeed");
        assert_eq!(&expected_digest, &nix_hash.digest_as_bytes());

        // not passing SRI, but hash algo out of band should fail
        NixHash::from_str(weird_base64, Some(HashAlgo::Sha256)).expect_err("must fail");
    }

    #[cfg(feature = "serde")]
    #[test]
    fn serialize_deserialize() {
        let nixhash_actual = NixHash::Sha256(hex!(
            "b3271e24c5049270430872bc786b3aad45372109fe1e741f5117c2ac3c583daf"
        ));
        let nixhash_str_json = "\"sha256-syceJMUEknBDCHK8eGs6rUU3IQn+HnQfURfCrDxYPa8=\"";

        let serialized = serde_json::to_string(&nixhash_actual).expect("can serialize");

        assert_eq!(nixhash_str_json, &serialized);

        let deserialized: NixHash =
            serde_json::from_str(nixhash_str_json).expect("must deserialize");
        assert_eq!(&nixhash_actual, &deserialized);
    }
}
