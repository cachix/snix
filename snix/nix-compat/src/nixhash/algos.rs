use std::fmt::Display;
use std::str::FromStr;

#[cfg(feature = "serde")]
use serde_with::{DeserializeFromStr, SerializeDisplay};

use crate::nixhash::Error;

/// This are the hash algorithms supported by cppnix.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
#[cfg_attr(feature = "serde", derive(DeserializeFromStr, SerializeDisplay))]
pub enum HashAlgo {
    Md5,
    Sha1,
    Sha256,
    Sha512,
}

impl HashAlgo {
    // return the number of bytes in the digest of the given hash algo.
    pub const fn digest_length(&self) -> usize {
        match self {
            HashAlgo::Sha1 => 20,
            HashAlgo::Sha256 => 32,
            HashAlgo::Sha512 => 64,
            HashAlgo::Md5 => 16,
        }
    }
}

impl Display for HashAlgo {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match &self {
            HashAlgo::Md5 => write!(f, "md5"),
            HashAlgo::Sha1 => write!(f, "sha1"),
            HashAlgo::Sha256 => write!(f, "sha256"),
            HashAlgo::Sha512 => write!(f, "sha512"),
        }
    }
}

/// TODO(Raito): this could be automated via macros, I suppose.
/// But this may be more expensive than just doing it by hand
/// and ensuring that is kept in sync.
#[cfg(feature = "serde")]
pub const SUPPORTED_ALGOS: [&str; 4] = ["md5", "sha1", "sha256", "sha512"];

impl FromStr for HashAlgo {
    type Err = Error;

    fn from_str(algo_str: &str) -> Result<Self, Self::Err> {
        match algo_str {
            "md5" => Ok(Self::Md5),
            "sha1" => Ok(Self::Sha1),
            "sha256" => Ok(Self::Sha256),
            "sha512" => Ok(Self::Sha512),
            _ => Err(Error::InvalidAlgo),
        }
    }
}

impl TryFrom<&str> for HashAlgo {
    type Error = Error;
    fn try_from(algo_str: &str) -> Result<Self, Self::Error> {
        algo_str.parse()
    }
}
