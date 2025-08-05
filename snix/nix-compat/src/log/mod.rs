//! Contains types Nix uses for its logging, visible in the "internal-json" log
//! messages as well as in nix-daemon communication.

#[cfg(feature = "serde")]
use serde::{Deserialize, Serialize};
#[cfg(feature = "serde")]
use tracing::warn;

/// Every "internal-json" log line emitted by Nix has this prefix.
pub const AT_NIX_PREFIX: &str = "@nix ";

/// The different verbosity levels Nix distinguishes.
#[derive(
    Clone, Debug, Eq, PartialEq, num_enum::TryFromPrimitive, num_enum::IntoPrimitive, Default,
)]
#[cfg_attr(
    feature = "serde",
    derive(Serialize, Deserialize),
    serde(try_from = "u64", into = "u64")
)]
#[cfg_attr(
    feature = "daemon",
    derive(nix_compat_derive::NixDeserialize, nix_compat_derive::NixSerialize),
    nix(try_from = "u64", into = "u64")
)]
#[repr(u64)]
pub enum VerbosityLevel {
    #[default]
    Error = 0,
    Warn = 1,
    Notice = 2,
    Info = 3,
    Talkative = 4,
    Chatty = 5,
    Debug = 6,
    Vomit = 7,
}

impl std::fmt::Display for VerbosityLevel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{}",
            match self {
                VerbosityLevel::Error => "error",
                VerbosityLevel::Warn => "warn",
                VerbosityLevel::Notice => "notice",
                VerbosityLevel::Info => "info",
                VerbosityLevel::Talkative => "talkative",
                VerbosityLevel::Chatty => "chatty",
                VerbosityLevel::Debug => "debug",
                VerbosityLevel::Vomit => "vomit",
            }
        )
    }
}

/// The different types of log messages Nix' `internal-json` format can
/// represent.
#[derive(Clone, Debug, Eq, PartialEq)]
#[cfg_attr(feature = "serde",
    derive(Serialize, Deserialize),
    serde(tag = "action", rename_all = "camelCase" /*, deny_unknown_fields */))]
// TODO: deny_unknown_fields doesn't seem to work in the testcases below
pub enum LogMessage<'a> {
    Start {
        #[cfg_attr(feature = "serde", serde(skip_serializing_if = "Option::is_none"))]
        fields: Option<Vec<Field<'a>>>,
        id: u64,
        level: VerbosityLevel,
        parent: u64,
        text: std::borrow::Cow<'a, str>,
        r#type: ActivityType,
    },

    Stop {
        id: u64,
    },

    Result {
        fields: Vec<Field<'a>>,
        id: u64,
        r#type: ResultType,
    },

    // FUTUREWORK: there sometimes seems to be column/file/line fields set to null, and a raw_msg field,
    // see msg_with_raw_msg testcase. These should be represented.
    Msg {
        level: VerbosityLevel,
        msg: std::borrow::Cow<'a, str>,
    },

    // Log lines like these are sent by nixpkgs stdenv, present in `nix log` outputs of individual builds.
    // They are also interpreted by Nix to re-emit [Self::Result]-style messages.
    SetPhase {
        phase: &'a str,
    },
}

#[cfg(feature = "serde")]
fn serialize_bytes_as_string<S>(b: &[u8], serializer: S) -> Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    match std::str::from_utf8(b) {
        Ok(s) => serializer.serialize_str(s),
        Err(_) => {
            warn!("encountered invalid utf-8 in JSON");
            serializer.serialize_bytes(b)
        }
    }
}

/// Fields in a log message can be either ints or strings.
/// Sometimes, Nix also uses invalid UTF-8 in here, so we use BStr.
#[derive(Clone, Debug, Eq, PartialEq)]
#[cfg_attr(feature = "serde", derive(Serialize, Deserialize), serde(untagged))]
pub enum Field<'a> {
    Int(u64),
    String(
        #[cfg_attr(feature = "serde", serde(serialize_with = "serialize_bytes_as_string"))]
        std::borrow::Cow<'a, [u8]>,
    ),
}

#[derive(Clone, Debug, Eq, PartialEq, num_enum::TryFromPrimitive, num_enum::IntoPrimitive)]
#[cfg_attr(
    feature = "serde",
    derive(Serialize, Deserialize),
    serde(try_from = "u8", into = "u8")
)]
#[repr(u8)]
pub enum ActivityType {
    Unknown = 0,
    CopyPath = 100,
    FileTransfer = 101,
    Realise = 102,
    CopyPaths = 103,
    Builds = 104,
    Build = 105,
    OptimiseStore = 106,
    VerifyPaths = 107,
    Substitute = 108,
    QueryPathInfo = 109,
    PostBuildHook = 110,
    BuildWaiting = 111,
    FetchTree = 112,
}

impl std::fmt::Display for ActivityType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{}",
            match self {
                ActivityType::Unknown => "unknown",
                ActivityType::CopyPath => "copy-path",
                ActivityType::FileTransfer => "file-transfer",
                ActivityType::Realise => "realise",
                ActivityType::CopyPaths => "copy-paths",
                ActivityType::Builds => "builds",
                ActivityType::Build => "build",
                ActivityType::OptimiseStore => "optimise-store",
                ActivityType::VerifyPaths => "verify-paths",
                ActivityType::Substitute => "substitute",
                ActivityType::QueryPathInfo => "query-path-info",
                ActivityType::PostBuildHook => "post-build-hook",
                ActivityType::BuildWaiting => "build-waiting",
                ActivityType::FetchTree => "fetch-tree",
            }
        )
    }
}

#[derive(Clone, Debug, Eq, PartialEq, num_enum::TryFromPrimitive, num_enum::IntoPrimitive)]
#[cfg_attr(
    feature = "serde",
    derive(Serialize, Deserialize),
    serde(try_from = "u8", into = "u8")
)]
#[repr(u8)]
pub enum ResultType {
    FileLinked = 100,
    BuildLogLine = 101,
    UntrustedPath = 102,
    CorruptedPath = 103,
    SetPhase = 104,
    Progress = 105,
    SetExpected = 106,
    PostBuildLogLine = 107,
    FetchStatus = 108,
}

impl<'a> LogMessage<'a> {
    /// Parses a given log message string into a [LogMessage].
    #[cfg(feature = "serde")]
    pub fn from_json_str(s: &'a str) -> Result<Self, Error> {
        let s = s.strip_prefix(AT_NIX_PREFIX).ok_or(Error::MissingPrefix)?;

        Ok(serde_json::from_str(s)?)
    }
}

#[cfg(feature = "serde")]
impl std::fmt::Display for LogMessage<'_> {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "{AT_NIX_PREFIX}{}",
            serde_json::to_string(self).expect("Failed to serialize LogMessage")
        )
    }
}

#[cfg(feature = "serde")]
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("Missing @nix prefix")]
    MissingPrefix,

    #[error("Failed to deserialize: {0}")]
    FailedDeserialize(#[from] serde_json::Error),
}

#[cfg(test)]
// prevent assert_matches! from complaining about expected_message being unused,
// while it *is* compared.
#[allow(unused_variables)]
mod test {
    use super::VerbosityLevel;
    #[cfg(feature = "serde")]
    use super::{ActivityType, Field, LogMessage, ResultType};
    #[cfg(feature = "serde")]
    use rstest::rstest;

    #[test]
    fn verbosity_level() {
        assert_eq!(
            VerbosityLevel::try_from(0).expect("must succeed"),
            VerbosityLevel::Error
        );
        assert_eq!(VerbosityLevel::default(), VerbosityLevel::Error);

        // Nix can be caused to send a verbosity level larger than itself knows about,
        // (by passing too many -v arguments) but we reject this.
        VerbosityLevel::try_from(42).expect_err("must fail parsing");
    }

    #[cfg(feature = "serde")]
    #[rstest]
    #[case::start(
        r#"@nix {"action":"start","id":1264799149195466,"level":5,"parent":0,"text":"copying '/nix/store/rfqxfljma55x8ybmyg07crnarvqx62sr-nixpkgs-src/pkgs/development/compilers/llvm/18/llvm/lit-shell-script-runner-set-dyld-library-path.patch' to the store","type":0}"#,
        LogMessage::Start {
            fields: None,
            id: 1264799149195466,
            level: VerbosityLevel::Chatty,
            parent: 0,
            text: "copying '/nix/store/rfqxfljma55x8ybmyg07crnarvqx62sr-nixpkgs-src/pkgs/development/compilers/llvm/18/llvm/lit-shell-script-runner-set-dyld-library-path.patch' to the store".into(),
            r#type: ActivityType::Unknown,
        },
        true
    )]
    #[case::stop(
        r#"@nix {"action":"stop","id":1264799149195466}"#,
        LogMessage::Stop {
            id: 1264799149195466,
        },
        true
    )]
    #[case::start_with_fields(
        r#"@nix {"action":"start","fields":["/nix/store/j3hy9syhvyqhghb13vk1433h81q50wcc-rust_tvix-store-0.1.0-linked","https://cache.nixos.org"],"id":1289035649646595,"level":4,"parent":0,"text":"querying info about '/nix/store/j3hy9syhvyqhghb13vk1433h81q50wcc-rust_tvix-store-0.1.0-linked' on 'https://cache.nixos.org'","type":109}"#,
        LogMessage::Start { fields: Some(vec![Field::String(b"/nix/store/j3hy9syhvyqhghb13vk1433h81q50wcc-rust_tvix-store-0.1.0-linked".into()),Field::String(b"https://cache.nixos.org".into())]), id: 1289035649646595, level: VerbosityLevel::Talkative, parent: 0, text: "querying info about '/nix/store/j3hy9syhvyqhghb13vk1433h81q50wcc-rust_tvix-store-0.1.0-linked' on 'https://cache.nixos.org'".into(), r#type: ActivityType::QueryPathInfo },
        true
    )]
    #[case::result(
        r#"@nix {"action":"result","fields":[0,0,0,0],"id":1289035649646594,"type":105}"#,
        LogMessage::Result {
            id: 1289035649646594,
            fields: vec![Field::Int(0), Field::Int(0), Field::Int(0), Field::Int(0)],
            r#type: ResultType::Progress
        },
        true
    )]
    #[case::msg(
        r#"@nix {"action":"msg","level":3,"msg":"  /nix/store/zdxxlb3p1vaq1dgh6vfc7c1c52ry4n2f-rust_opentelemetry-semantic-conventions-0.27.0.drv"}"#,
        LogMessage::Msg { level: VerbosityLevel::Info, msg: "  /nix/store/zdxxlb3p1vaq1dgh6vfc7c1c52ry4n2f-rust_opentelemetry-semantic-conventions-0.27.0.drv".into() },
        true
    )]
    #[case::msg_with_raw_msg(
        r#"@nix {"action":"msg","column":null,"file":null,"level":0,"line":null,"msg":"\u001b[31;1merror:\u001b[0m interrupted by the user","raw_msg":"interrupted by the user"}"#,
        LogMessage::Msg {
            level: VerbosityLevel::Error,
            msg: "\u{001b}[31;1merror:\u{001b}[0m interrupted by the user".into(),
        },
        // FUTUREWORK: represent file/column/line/raw_msg and drop the expected_roundtrip arg alltogether
        false
    )]
    #[case::result_with_fields_int(
        r#"@nix {"action":"result","fields":[101,146944],"id":15116785938335501,"type":106}"#,
        LogMessage::Result { fields: vec![
            Field::Int(101),
            Field::Int(146944),
        ], id: 15116785938335501, r#type: ResultType::SetExpected },
        true
    )]
    #[case::set_phase(
        r#"@nix {"action":"setPhase","phase":"unpackPhase"}"#,
        LogMessage::SetPhase {
            phase: "unpackPhase"
        },
        true
    )]
    #[case::set_phase_result(
        r#"@nix {"action":"result","fields":["unpackPhase"],"id":418969764757508,"type":104}"#,
        LogMessage::Result {
            fields: vec![Field::String(b"unpackPhase".into())],
            id: 418969764757508,
            r#type: ResultType::SetPhase,
        },
        true
    )]
    fn serialize_deserialize(
        #[case] input_str: &str,
        #[case] expected_logmessage: LogMessage,
        #[case] expected_roundtrip: bool,
    ) {
        pretty_assertions::assert_matches!(
            LogMessage::from_json_str(input_str),
            expected_logmessage,
            "Expected from_str to return the expected LogMessage"
        );

        if expected_roundtrip {
            assert_eq!(
                input_str,
                expected_logmessage.to_string(),
                "Expected LogMessage to roundtrip to input_str"
            );
        }
    }
}
