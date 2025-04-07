use bytes::Bytes;
use data_encoding::BASE64;
use std::str::FromStr;
use thiserror::Error;

#[derive(PartialEq, Eq, Hash)]
#[repr(transparent)]
pub struct B3Digest([u8; Self::LENGTH]);

impl B3Digest {
    pub const LENGTH: usize = blake3::OUT_LEN;
}

// TODO: allow converting these errors to crate::Error
#[derive(Error, Debug, PartialEq)]
pub enum Error {
    #[error("invalid digest length: {0}")]
    InvalidDigestLen(usize),
    #[error("invalid hash type: expected a 'blake3-' prefixed digest")]
    InvalidHashType,
}

impl AsRef<[u8; B3Digest::LENGTH]> for B3Digest {
    fn as_ref(&self) -> &[u8; Self::LENGTH] {
        &self.0
    }
}

impl std::ops::Deref for B3Digest {
    type Target = [u8; Self::LENGTH];

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl From<B3Digest> for bytes::Bytes {
    fn from(val: B3Digest) -> Self {
        Bytes::copy_from_slice(&val.0)
    }
}

impl From<blake3::Hash> for B3Digest {
    fn from(value: blake3::Hash) -> Self {
        Self(*value.as_bytes())
    }
}
impl From<digest::Output<blake3::Hasher>> for B3Digest {
    fn from(value: digest::Output<blake3::Hasher>) -> Self {
        Self(value.into())
    }
}

impl TryFrom<&[u8]> for B3Digest {
    type Error = Error;

    // constructs a [B3Digest] from a &[u8].
    // Returns an error if the digest has the wrong length.
    fn try_from(value: &[u8]) -> Result<Self, Self::Error> {
        Ok(Self(
            value
                .try_into()
                .map_err(|_e| Error::InvalidDigestLen(value.len()))?,
        ))
    }
}

impl TryFrom<bytes::Bytes> for B3Digest {
    type Error = Error;

    fn try_from(value: bytes::Bytes) -> Result<Self, Self::Error> {
        value[..].try_into()
    }
}

impl TryFrom<Vec<u8>> for B3Digest {
    type Error = Error;

    fn try_from(value: Vec<u8>) -> Result<Self, Self::Error> {
        value[..].try_into()
    }
}

impl From<&[u8; B3Digest::LENGTH]> for B3Digest {
    fn from(value: &[u8; B3Digest::LENGTH]) -> Self {
        Self(*value)
    }
}

impl From<B3Digest> for [u8; B3Digest::LENGTH] {
    fn from(value: B3Digest) -> Self {
        value.0
    }
}

impl Clone for B3Digest {
    fn clone(&self) -> Self {
        Self(self.0.to_owned())
    }
}

impl std::fmt::Display for B3Digest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("blake3-").unwrap();
        BASE64.encode_write(&self.0, f)
    }
}

impl std::fmt::Debug for B3Digest {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("blake3-").unwrap();
        BASE64.encode_write(&self.0, f)
    }
}

impl FromStr for B3Digest {
    type Err = Error;

    fn from_str(s: &str) -> Result<Self, Self::Err> {
        if !s.starts_with("blake3-") {
            return Err(Error::InvalidHashType);
        }
        let encoded = &s[7..];
        let decoded = BASE64
            .decode(encoded.as_bytes())
            .map_err(|_| Error::InvalidDigestLen(s.len()))?;
        decoded.as_slice().try_into()
    }
}
