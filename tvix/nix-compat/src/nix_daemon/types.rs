use crate::wire::de::Error;
use crate::{
    narinfo::Signature,
    nixhash::CAHash,
    store_path::StorePath,
    wire::{
        de::{NixDeserialize, NixRead},
        ser::{NixSerialize, NixWrite},
    },
};
use nix_compat_derive::{NixDeserialize, NixSerialize};
use std::future::Future;

/// Marker type that consumes/sends and ignores a u64.
#[derive(Clone, Debug, NixDeserialize, NixSerialize)]
#[nix(from = "u64", into = "u64")]
pub struct IgnoredZero;
impl From<u64> for IgnoredZero {
    fn from(_: u64) -> Self {
        IgnoredZero
    }
}

impl From<IgnoredZero> for u64 {
    fn from(_: IgnoredZero) -> Self {
        0
    }
}

#[derive(Debug, NixSerialize)]
pub struct TraceLine {
    have_pos: IgnoredZero,
    hint: String,
}

/// Represents an error returned by the nix-daemon to its client.
///
/// Adheres to the format described in serialization.md
#[derive(NixSerialize)]
pub struct NixError {
    #[nix(version = "26..")]
    type_: &'static str,

    #[nix(version = "26..")]
    level: u64,

    #[nix(version = "26..")]
    name: &'static str,

    msg: String,
    #[nix(version = "26..")]
    have_pos: IgnoredZero,

    #[nix(version = "26..")]
    traces: Vec<TraceLine>,

    #[nix(version = "..=25")]
    exit_status: u64,
}

impl NixError {
    pub fn new(msg: String) -> Self {
        Self {
            type_: "Error",
            level: 0, // error
            name: "Error",
            msg,
            have_pos: IgnoredZero {},
            traces: vec![],
            exit_status: 1,
        }
    }
}

nix_compat_derive::nix_serialize_remote!(#[nix(display)] Signature<String>);

impl NixDeserialize for Signature<String> {
    async fn try_deserialize<R>(reader: &mut R) -> Result<Option<Self>, R::Error>
    where
        R: ?Sized + NixRead + Send,
    {
        let value: Option<String> = reader.try_read_value().await?;
        match value {
            Some(value) => Ok(Some(
                Signature::<String>::parse(&value).map_err(R::Error::invalid_data)?,
            )),
            None => Ok(None),
        }
    }
}

impl NixSerialize for CAHash {
    async fn serialize<W>(&self, writer: &mut W) -> Result<(), W::Error>
    where
        W: NixWrite,
    {
        writer.write_value(&self.to_nix_nixbase32_string()).await
    }
}

impl NixSerialize for Option<CAHash> {
    async fn serialize<W>(&self, writer: &mut W) -> Result<(), W::Error>
    where
        W: NixWrite,
    {
        match self {
            Some(value) => writer.write_value(value).await,
            None => writer.write_value("").await,
        }
    }
}

impl NixDeserialize for CAHash {
    async fn try_deserialize<R>(reader: &mut R) -> Result<Option<Self>, R::Error>
    where
        R: ?Sized + NixRead + Send,
    {
        let value: Option<String> = reader.try_read_value().await?;
        match value {
            Some(value) => Ok(Some(CAHash::from_nix_hex_str(&value).ok_or_else(|| {
                R::Error::invalid_data(format!("Invalid cahash {}", value))
            })?)),
            None => Ok(None),
        }
    }
}

impl NixDeserialize for Option<CAHash> {
    async fn try_deserialize<R>(reader: &mut R) -> Result<Option<Self>, R::Error>
    where
        R: ?Sized + NixRead + Send,
    {
        let value: Option<String> = reader.try_read_value().await?;
        match value {
            Some(value) => {
                if value.is_empty() {
                    Ok(None)
                } else {
                    Ok(Some(Some(CAHash::from_nix_hex_str(&value).ok_or_else(
                        || R::Error::invalid_data(format!("Invalid cahash {}", value)),
                    )?)))
                }
            }
            None => Ok(None),
        }
    }
}

impl NixSerialize for Option<UnkeyedValidPathInfo> {
    async fn serialize<W>(&self, writer: &mut W) -> Result<(), W::Error>
    where
        W: NixWrite,
    {
        match self {
            Some(value) => {
                writer.write_value(&true).await?;
                writer.write_value(value).await
            }
            None => writer.write_value(&false).await,
        }
    }
}

// Custom implementation since FromStr does not use from_absolute_path
impl NixDeserialize for StorePath<String> {
    async fn try_deserialize<R>(reader: &mut R) -> Result<Option<Self>, R::Error>
    where
        R: ?Sized + NixRead + Send,
    {
        use crate::wire::de::Error;
        if let Some(buf) = reader.try_read_bytes().await? {
            let result = StorePath::<String>::from_absolute_path(&buf);
            result.map(Some).map_err(R::Error::invalid_data)
        } else {
            Ok(None)
        }
    }
}

impl NixDeserialize for Option<StorePath<String>> {
    async fn try_deserialize<R>(reader: &mut R) -> Result<Option<Self>, R::Error>
    where
        R: ?Sized + NixRead + Send,
    {
        use crate::wire::de::Error;
        if let Some(buf) = reader.try_read_bytes().await? {
            if buf.is_empty() {
                Ok(Some(None))
            } else {
                let result = StorePath::<String>::from_absolute_path(&buf);
                result
                    .map(|r| Some(Some(r)))
                    .map_err(R::Error::invalid_data)
            }
        } else {
            Ok(Some(None))
        }
    }
}

// Custom implementation since Display does not use absolute paths.
impl<S> NixSerialize for StorePath<S>
where
    S: AsRef<str>,
{
    fn serialize<W>(&self, writer: &mut W) -> impl Future<Output = Result<(), W::Error>> + Send
    where
        W: NixWrite,
    {
        let sp = self.to_absolute_path();
        async move { writer.write_value(&sp).await }
    }
}

// Writes StorePath or an empty string.
impl NixSerialize for Option<StorePath<String>> {
    async fn serialize<W>(&self, writer: &mut W) -> Result<(), W::Error>
    where
        W: NixWrite,
    {
        match self {
            Some(value) => writer.write_value(value).await,
            None => writer.write_value("").await,
        }
    }
}

#[derive(NixSerialize, Debug, Clone, Default, PartialEq)]
pub struct UnkeyedValidPathInfo {
    pub deriver: Option<StorePath<String>>,
    pub nar_hash: String,
    pub references: Vec<StorePath<String>>,
    pub registration_time: u64,
    pub nar_size: u64,
    pub ultimate: bool,
    pub signatures: Vec<Signature<String>>,
    pub ca: Option<CAHash>,
}

/// Request tuple for [super::worker_protocol::Operation::QueryValidPaths]
#[derive(NixDeserialize)]
pub struct QueryValidPaths {
    // Paths to query
    pub paths: Vec<StorePath<String>>,

    // Whether to try and substitute the paths.
    #[nix(version = "27..")]
    pub substitute: bool,
}

/// newtype wrapper for the byte array that correctly implements NixSerialize, NixDeserialize.
#[derive(Debug)]
pub struct NarHash([u8; 32]);

impl std::ops::Deref for NarHash {
    type Target = [u8; 32];

    fn deref(&self) -> &Self::Target {
        &self.0
    }
}

impl NixDeserialize for NarHash {
    async fn try_deserialize<R>(reader: &mut R) -> Result<Option<Self>, R::Error>
    where
        R: ?Sized + NixRead + Send,
    {
        if let Some(bytes) = reader.try_read_bytes().await? {
            let result = data_encoding::HEXLOWER
                .decode(bytes.as_ref())
                .map_err(R::Error::invalid_data)?;
            Ok(Some(NarHash(result.try_into().map_err(|_| {
                R::Error::invalid_data("incorrect length")
            })?)))
        } else {
            Ok(None)
        }
    }
}

/// Request type for [super::worker_protocol::Operation::AddToStoreNar]
#[derive(NixDeserialize, Debug)]
pub struct AddToStoreNarRequest {
    // - path :: [StorePath][se-StorePath]
    pub path: StorePath<String>,
    // - deriver :: [OptStorePath][se-OptStorePath]
    pub deriver: Option<StorePath<String>>,
    // - narHash :: [NARHash][se-NARHash] - always sha256
    pub nar_hash: NarHash,
    // - references :: [Set][se-Set] of [StorePath][se-StorePath]
    pub references: Vec<StorePath<String>>,
    // - registrationTime :: [Time][se-Time]
    pub registration_time: u64,
    // - narSize :: [UInt64][se-UInt64]
    pub nar_size: u64,
    // - ultimate :: [Bool64][se-Bool64]
    pub ultimate: bool,
    // - signatures :: [Set][se-Set] of [Signature][se-Signature]
    pub signatures: Vec<Signature<String>>,
    // - ca :: [OptContentAddress][se-OptContentAddress]
    pub ca: Option<CAHash>,
    // - repair :: [Bool64][se-Bool64]
    pub repair: bool,
    // - dontCheckSigs :: [Bool64][se-Bool64]
    pub dont_check_sigs: bool,
}
