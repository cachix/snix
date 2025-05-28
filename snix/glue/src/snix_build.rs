//! This module contains glue code translating from
//! [nix_compat::derivation::Derivation] to [snix_build::buildservice::BuildRequest].

use std::collections::{BTreeMap, HashSet, VecDeque};
use std::future::Future;
use std::path::PathBuf;

use async_stream::try_stream;
use bstr::BString;
use bytes::Bytes;
use futures::Stream;
use nix_compat::derivation::Output;
use nix_compat::store_path::hash_placeholder;
use nix_compat::{derivation::Derivation, nixbase32, store_path::StorePath};
use sha2::{Digest, Sha256};
use snix_build::buildservice::{AdditionalFile, BuildConstraints, BuildRequest, EnvVar};
use snix_castore::Node;
use snix_store::path_info::PathInfo;
use tracing::warn;

use crate::known_paths::KnownPaths;

/// These are the environment variables that Nix sets in its sandbox for every
/// build.
const NIX_ENVIRONMENT_VARS: [(&str, &str); 12] = [
    ("HOME", "/homeless-shelter"),
    ("NIX_BUILD_CORES", "0"), // TODO: make this configurable?
    ("NIX_BUILD_TOP", "/build"),
    ("NIX_LOG_FD", "2"),
    ("NIX_STORE", "/nix/store"),
    ("PATH", "/path-not-set"),
    ("PWD", "/build"),
    ("TEMP", "/build"),
    ("TEMPDIR", "/build"),
    ("TERM", "xterm-256color"),
    ("TMP", "/build"),
    ("TMPDIR", "/build"),
];

/// Get a stream of a transitive input closure for a derivation.
/// It's used for input propagation into the build and nixbase32 needle propagation
/// for build output refscanning.
pub(crate) fn get_all_inputs<'a, F, Fut>(
    derivation: &'a Derivation,
    known_paths: &'a KnownPaths,
    get_path_info: F,
) -> impl Stream<Item = Result<(StorePath<String>, Node), std::io::Error>> + use<F, Fut>
where
    F: Fn(StorePath<String>) -> Fut,
    Fut: Future<Output = std::io::Result<Option<PathInfo>>>,
{
    let mut visited: HashSet<StorePath<String>> = HashSet::new();
    let mut queue: VecDeque<StorePath<String>> = derivation
        .input_sources
        .iter()
        .cloned()
        .chain(
            derivation
                .input_derivations
                .iter()
                .flat_map(|(drv_path, outs)| {
                    let drv = known_paths.get_drv_by_drvpath(drv_path).expect("drv Bug!!");
                    outs.iter().map(move |output| {
                        drv.outputs
                            .get(output)
                            .expect("No output bug!")
                            .path
                            .as_ref()
                            .expect("output has no store path")
                            .clone()
                    })
                }),
        )
        .collect();
    try_stream! {
        while let Some(store_path) = queue.pop_front() {
                let info = get_path_info(store_path).await?.ok_or(std::io::Error::other("path_info not present"))?;
                    for reference in info.references {
                        if visited.insert(reference.clone()) {
                            queue.push_back(reference);
                        }
                    }

                    yield (info.store_path, info.node);


        }
    }
}

/// Takes a [Derivation] and turns it into a [snix_build::buildservice::BuildRequest].
/// It assumes the Derivation has been validated, and all referenced output paths are present in `inputs`.
pub(crate) fn derivation_to_build_request(
    derivation: &Derivation,
    inputs: &BTreeMap<StorePath<String>, Node>,
) -> std::io::Result<BuildRequest> {
    debug_assert!(derivation.validate(true).is_ok(), "drv must validate");

    // produce command_args, which is builder and arguments in a Vec.
    let mut command_args: Vec<String> = Vec::with_capacity(derivation.arguments.len() + 1);
    command_args.push(derivation.builder.clone());
    command_args.extend_from_slice(
        derivation
            .arguments
            .iter()
            .map(|arg| replace_placeholders(arg, &derivation.outputs))
            .collect::<Vec<String>>()
            .as_slice(),
    );

    // Produce environment_vars and additional files.
    // We use a BTreeMap while producing, and only realize the resulting Vec
    // while populating BuildRequest, so we don't need to worry about ordering.
    let mut environment_vars: BTreeMap<String, Bytes> = BTreeMap::new();
    let mut additional_files: BTreeMap<String, Bytes> = BTreeMap::new();

    // Start with some the ones that nix magically sets:
    environment_vars.extend(
        NIX_ENVIRONMENT_VARS
            .iter()
            .map(|(k, v)| (k.to_string(), Bytes::from_static(v.as_bytes()))),
    );

    // extend / overwrite with the keys set in the derivation environment itself.
    // TODO: check if this order is correct, and environment vars set in the
    // *Derivation actually* have priority.
    environment_vars.extend(derivation.environment.iter().map(|(k, v)| {
        (
            k.clone(),
            Bytes::from(replace_placeholders_b(v, &derivation.outputs).to_vec()),
        )
    }));

    handle_pass_as_file(&mut environment_vars, &mut additional_files)?;

    // TODO: handle __json (structured attrs, provide JSON file and source-able bash script)

    // Produce constraints.
    let mut constraints = HashSet::from([
        BuildConstraints::System(derivation.system.clone()),
        BuildConstraints::ProvideBinSh,
    ]);

    if derivation.outputs.len() == 1
        && derivation
            .outputs
            .get("out")
            .expect("Snix bug: Derivation has no out output")
            .is_fixed()
    {
        constraints.insert(BuildConstraints::NetworkAccess);
    }

    Ok(BuildRequest {
        // Importantly, this must match the order of get_refscan_needles, since users may use that
        // function to map back from the found needles to a store path
        refscan_needles: derivation
            .outputs
            .values()
            .filter_map(|output| output.path.as_ref())
            .map(|path| nixbase32::encode(path.digest()))
            .chain(inputs.keys().map(|path| nixbase32::encode(path.digest())))
            .collect(),
        command_args,

        outputs: derivation
            .outputs
            .values()
            .map(|e| PathBuf::from(e.path_str()[1..].to_owned()))
            .collect(),

        // Turn this into a sorted-by-key Vec<EnvVar>.
        environment_vars: environment_vars
            .into_iter()
            .map(|(key, value)| EnvVar { key, value })
            .collect(),
        inputs: inputs
            .iter()
            .map(|(path, node)| {
                (
                    path.to_string()
                        .as_str()
                        .try_into()
                        .expect("Snix bug: unable to convert store path basename to PathComponent"),
                    node.clone(),
                )
            })
            .collect(),
        inputs_dir: nix_compat::store_path::STORE_DIR[1..].into(),
        constraints,
        working_dir: "build".into(),
        scratch_paths: vec![
            "build".into(),
            // This is in here because Nix allows you to do
            // `pkgs.runCommand "foo" {} "mkdir -p $out;touch /nix/store/aaaa"`
            // (throwing away the /nix/store/aaaa post-build),
            // not because it's a sane thing to do.
            // FUTUREWORK: check if nothing exploits this.
            "nix/store".into(),
        ],
        additional_files: additional_files
            .into_iter()
            .map(|(path, contents)| AdditionalFile {
                path: PathBuf::from(path),
                contents,
            })
            .collect(),
    })
}

/// handle passAsFile, if set.
/// For each env $x in that list, the original env is removed, and a $xPath
/// environment var added instead, referring to a path inside the build with
/// the contents from the original env var.
fn handle_pass_as_file(
    environment_vars: &mut BTreeMap<String, Bytes>,
    additional_files: &mut BTreeMap<String, Bytes>,
) -> std::io::Result<()> {
    let pass_as_file = environment_vars.get("passAsFile").map(|v| {
        // Convert pass_as_file to string.
        // When it gets here, it contains a space-separated list of env var
        // keys, which must be strings.
        String::from_utf8(v.to_vec())
    });

    if let Some(pass_as_file) = pass_as_file {
        let pass_as_file = pass_as_file.map_err(|_| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "passAsFile elements are no valid utf8 strings",
            )
        })?;

        for x in pass_as_file.split(' ') {
            match environment_vars.remove_entry(x) {
                Some((k, contents)) => {
                    let (new_k, path) = calculate_pass_as_file_env(&k);

                    additional_files.insert(path[1..].to_string(), contents);
                    environment_vars.insert(new_k, Bytes::from(path));
                }
                None => {
                    return Err(std::io::Error::new(
                        std::io::ErrorKind::InvalidData,
                        "passAsFile refers to non-existent env key",
                    ));
                }
            }
        }
    }

    Ok(())
}

/// For a given key k in a derivation environment that's supposed to be passed as file,
/// calculate the ${k}Path key and filepath value that it's being replaced with
/// while preparing the build.
/// The filepath is `/build/.attrs-${nixbase32(sha256(key))`.
fn calculate_pass_as_file_env(k: &str) -> (String, String) {
    (
        format!("{}Path", k),
        format!(
            "/build/.attr-{}",
            nixbase32::encode(&Sha256::new_with_prefix(k).finalize())
        ),
    )
}

/// Replace all references to `placeholder outputName` inside the derivation
fn replace_placeholders(s: &str, outputs: &BTreeMap<String, Output>) -> String {
    let mut s = s.to_owned();
    for (out_name, output) in outputs {
        let placeholder = hash_placeholder(out_name.as_str());
        if let Some(path) = output.path.as_ref() {
            s = s.replace(&placeholder, &path.to_absolute_path());
        } else {
            warn!(
                output.name = out_name,
                "output should have a path during placeholder replacement"
            );
        }
    }
    s
}

/// Replace all references to `placeholder outputName` inside the derivation
fn replace_placeholders_b(s: &BString, outputs: &BTreeMap<String, Output>) -> BString {
    use bstr::ByteSlice;
    let mut s = s.clone();
    for (out_name, output) in outputs {
        let placeholder = hash_placeholder(out_name.as_str());
        if let Some(path) = output.path.as_ref() {
            s = s
                .replace(placeholder.as_bytes(), path.to_absolute_path().as_bytes())
                .into();
        } else {
            warn!(
                output.name = out_name,
                "output should have a path during placeholder replacement"
            );
        }
    }
    s
}

#[cfg(test)]
mod test {
    use bytes::Bytes;
    use nix_compat::store_path::hash_placeholder;
    use nix_compat::{derivation::Derivation, store_path::StorePath};
    use snix_castore::fixtures::DUMMY_DIGEST;
    use snix_castore::{Node, PathComponent};
    use std::collections::{BTreeMap, HashSet};
    use std::sync::LazyLock;

    use snix_build::buildservice::{AdditionalFile, BuildConstraints, BuildRequest, EnvVar};

    use crate::known_paths::KnownPaths;
    use crate::snix_build::NIX_ENVIRONMENT_VARS;

    use super::derivation_to_build_request;

    static INPUT_NODE_FOO_NAME: LazyLock<Bytes> =
        LazyLock::new(|| "mp57d33657rf34lzvlbpfa1gjfv5gmpg-bar".into());

    static INPUT_NODE_FOO: LazyLock<Node> = LazyLock::new(|| Node::Directory {
        digest: DUMMY_DIGEST.clone(),
        size: 42,
    });

    #[test]
    fn test_derivation_to_build_request() {
        let aterm_bytes = include_bytes!("tests/ch49594n9avinrf8ip0aslidkc4lxkqv-foo.drv");

        let dep_drv_bytes = include_bytes!("tests/ss2p4wmxijn652haqyd7dckxwl4c7hxx-bar.drv");

        let derivation1 = Derivation::from_aterm_bytes(aterm_bytes).expect("drv1 must parse");
        let drv_path1 =
            StorePath::<String>::from_bytes("ch49594n9avinrf8ip0aslidkc4lxkqv-foo.drv".as_bytes())
                .expect("drv path1 must parse");
        let derivation2 = Derivation::from_aterm_bytes(dep_drv_bytes).expect("drv2 must parse");
        let drv_path2 =
            StorePath::<String>::from_bytes("ss2p4wmxijn652haqyd7dckxwl4c7hxx-bar.drv".as_bytes())
                .expect("drv path2 must parse");

        let mut known_paths = KnownPaths::default();

        known_paths.add_derivation(drv_path2, derivation2);
        known_paths.add_derivation(drv_path1, derivation1.clone());

        let build_request = derivation_to_build_request(
            &derivation1,
            &BTreeMap::from([(
                StorePath::<String>::from_bytes(&INPUT_NODE_FOO_NAME.clone()).unwrap(),
                INPUT_NODE_FOO.clone(),
            )]),
        )
        .expect("must succeed");

        let mut expected_environment_vars = vec![
            EnvVar {
                key: "bar".into(),
                value: "/nix/store/mp57d33657rf34lzvlbpfa1gjfv5gmpg-bar".into(),
            },
            EnvVar {
                key: "builder".into(),
                value: ":".into(),
            },
            EnvVar {
                key: "name".into(),
                value: "foo".into(),
            },
            EnvVar {
                key: "out".into(),
                value: "/nix/store/fhaj6gmwns62s6ypkcldbaj2ybvkhx3p-foo".into(),
            },
            EnvVar {
                key: "system".into(),
                value: ":".into(),
            },
        ];

        expected_environment_vars.extend(NIX_ENVIRONMENT_VARS.iter().map(|(k, v)| EnvVar {
            key: k.to_string(),
            value: Bytes::from_static(v.as_bytes()),
        }));

        expected_environment_vars.sort_unstable_by_key(|e| e.key.to_owned());

        assert_eq!(
            BuildRequest {
                command_args: vec![":".into()],
                outputs: vec!["nix/store/fhaj6gmwns62s6ypkcldbaj2ybvkhx3p-foo".into()],
                environment_vars: expected_environment_vars,
                inputs: BTreeMap::from([(
                    PathComponent::try_from(INPUT_NODE_FOO_NAME.clone()).unwrap(),
                    INPUT_NODE_FOO.clone()
                )]),
                inputs_dir: "nix/store".into(),
                constraints: HashSet::from([
                    BuildConstraints::System(derivation1.system.clone()),
                    BuildConstraints::ProvideBinSh
                ]),
                additional_files: vec![],
                working_dir: "build".into(),
                scratch_paths: vec!["build".into(), "nix/store".into()],
                refscan_needles: vec![
                    "fhaj6gmwns62s6ypkcldbaj2ybvkhx3p".into(),
                    "mp57d33657rf34lzvlbpfa1gjfv5gmpg".into()
                ],
            },
            build_request
        );
    }

    #[test]
    fn test_drv_with_placeholders_to_build_request() {
        let aterm_bytes =
            include_bytes!("tests/18m7y1d025lqgrzx8ypnhjbvq23z2kda-with-placeholders.drv");
        let derivation = Derivation::from_aterm_bytes(aterm_bytes).expect("must parse");

        let build_request =
            derivation_to_build_request(&derivation, &BTreeMap::from([])).expect("must succeed");
        let mut expected_environment_vars = vec![
            EnvVar {
                key: "FOO".into(),
                value: "/nix/store/dgapb8kh5gis4w7hzfl5725sx5gam0nz-with-placeholders".into(),
            },
            EnvVar {
                key: "BAR".into(),
                // Non existent output placeholders should not get replaced.
                value: hash_placeholder("non-existent").into(),
            },
            EnvVar {
                key: "builder".into(),
                value: "/bin/sh".into(),
            },
            EnvVar {
                key: "name".into(),
                value: "with-placeholders".into(),
            },
            EnvVar {
                key: "out".into(),
                value: "/nix/store/dgapb8kh5gis4w7hzfl5725sx5gam0nz-with-placeholders".into(),
            },
            EnvVar {
                key: "system".into(),
                value: "x86_64-linux".into(),
            },
        ];
        expected_environment_vars.extend(NIX_ENVIRONMENT_VARS.iter().map(|(k, v)| EnvVar {
            key: k.to_string(),
            value: Bytes::from_static(v.as_bytes()),
        }));

        expected_environment_vars.sort_unstable_by_key(|e| e.key.to_owned());
        assert_eq!(
            BuildRequest {
                command_args: vec![
                    "/bin/sh".into(),
                    "-c".into(),
                    "/nix/store/dgapb8kh5gis4w7hzfl5725sx5gam0nz-with-placeholders".into(),
                    // Non existent output placeholders should not get replaced.
                    hash_placeholder("non-existent"),
                ],
                outputs: vec![
                    "nix/store/dgapb8kh5gis4w7hzfl5725sx5gam0nz-with-placeholders".into()
                ],
                environment_vars: expected_environment_vars,
                inputs: BTreeMap::new(),
                inputs_dir: "nix/store".into(),
                constraints: HashSet::from([
                    BuildConstraints::System(derivation.system.clone()),
                    BuildConstraints::ProvideBinSh
                ]),
                additional_files: vec![],
                working_dir: "build".into(),
                scratch_paths: vec!["build".into(), "nix/store".into()],
                refscan_needles: vec!["dgapb8kh5gis4w7hzfl5725sx5gam0nz".into()],
            },
            build_request
        );
    }

    #[test]
    fn test_fod_to_build_request() {
        let aterm_bytes = include_bytes!("tests/0hm2f1psjpcwg8fijsmr4wwxrx59s092-bar.drv");

        let derivation = Derivation::from_aterm_bytes(aterm_bytes).expect("must parse");

        let build_request =
            derivation_to_build_request(&derivation, &BTreeMap::from([])).expect("must succeed");

        let mut expected_environment_vars = vec![
            EnvVar {
                key: "builder".into(),
                value: ":".into(),
            },
            EnvVar {
                key: "name".into(),
                value: "bar".into(),
            },
            EnvVar {
                key: "out".into(),
                value: "/nix/store/4q0pg5zpfmznxscq3avycvf9xdvx50n3-bar".into(),
            },
            EnvVar {
                key: "outputHash".into(),
                value: "08813cbee9903c62be4c5027726a418a300da4500b2d369d3af9286f4815ceba".into(),
            },
            EnvVar {
                key: "outputHashAlgo".into(),
                value: "sha256".into(),
            },
            EnvVar {
                key: "outputHashMode".into(),
                value: "recursive".into(),
            },
            EnvVar {
                key: "system".into(),
                value: ":".into(),
            },
        ];

        expected_environment_vars.extend(NIX_ENVIRONMENT_VARS.iter().map(|(k, v)| EnvVar {
            key: k.to_string(),
            value: Bytes::from_static(v.as_bytes()),
        }));

        expected_environment_vars.sort_unstable_by_key(|e| e.key.to_owned());

        assert_eq!(
            BuildRequest {
                command_args: vec![":".to_string()],
                outputs: vec!["nix/store/4q0pg5zpfmznxscq3avycvf9xdvx50n3-bar".into()],
                environment_vars: expected_environment_vars,
                inputs: BTreeMap::new(),
                inputs_dir: "nix/store".into(),
                constraints: HashSet::from([
                    BuildConstraints::System(derivation.system.clone()),
                    BuildConstraints::NetworkAccess,
                    BuildConstraints::ProvideBinSh
                ]),
                additional_files: vec![],
                working_dir: "build".into(),
                scratch_paths: vec!["build".into(), "nix/store".into()],
                refscan_needles: vec!["4q0pg5zpfmznxscq3avycvf9xdvx50n3".into()],
            },
            build_request
        );
    }

    #[test]
    fn test_pass_as_file() {
        // (builtins.derivation { "name" = "foo"; passAsFile = ["bar" "baz"]; bar = "baz"; baz = "bar"; system = ":"; builder = ":";}).drvPath
        let aterm_bytes = r#"Derive([("out","/nix/store/pp17lwra2jkx8rha15qabg2q3wij72lj-foo","","")],[],[],":",":",[],[("bar","baz"),("baz","bar"),("builder",":"),("name","foo"),("out","/nix/store/pp17lwra2jkx8rha15qabg2q3wij72lj-foo"),("passAsFile","bar baz"),("system",":")])"#.as_bytes();

        let derivation = Derivation::from_aterm_bytes(aterm_bytes).expect("must parse");

        let build_request =
            derivation_to_build_request(&derivation, &BTreeMap::from([])).expect("must succeed");

        let mut expected_environment_vars = vec![
            // Note how bar and baz are not present in the env anymore,
            // but replaced with barPath, bazPath respectively.
            EnvVar {
                key: "barPath".into(),
                value: "/build/.attr-1fcgpy7vc4ammr7s17j2xq88scswkgz23dqzc04g8sx5vcp2pppw".into(),
            },
            EnvVar {
                key: "bazPath".into(),
                value: "/build/.attr-15l04iksj1280dvhbzdq9ai3wlf8ac2188m9qv0gn81k9nba19ds".into(),
            },
            EnvVar {
                key: "builder".into(),
                value: ":".into(),
            },
            EnvVar {
                key: "name".into(),
                value: "foo".into(),
            },
            EnvVar {
                key: "out".into(),
                value: "/nix/store/pp17lwra2jkx8rha15qabg2q3wij72lj-foo".into(),
            },
            // passAsFile stays around
            EnvVar {
                key: "passAsFile".into(),
                value: "bar baz".into(),
            },
            EnvVar {
                key: "system".into(),
                value: ":".into(),
            },
        ];

        expected_environment_vars.extend(NIX_ENVIRONMENT_VARS.iter().map(|(k, v)| EnvVar {
            key: k.to_string(),
            value: Bytes::from_static(v.as_bytes()),
        }));

        expected_environment_vars.sort_unstable_by_key(|e| e.key.to_owned());

        assert_eq!(
            BuildRequest {
                command_args: vec![":".to_string()],
                outputs: vec!["nix/store/pp17lwra2jkx8rha15qabg2q3wij72lj-foo".into()],
                environment_vars: expected_environment_vars,
                inputs: BTreeMap::new(),
                inputs_dir: "nix/store".into(),
                constraints: HashSet::from([
                    BuildConstraints::System(derivation.system.clone()),
                    BuildConstraints::ProvideBinSh,
                ]),
                additional_files: vec![
                    // baz env
                    AdditionalFile {
                        path: "build/.attr-15l04iksj1280dvhbzdq9ai3wlf8ac2188m9qv0gn81k9nba19ds"
                            .into(),
                        contents: "bar".into()
                    },
                    // bar env
                    AdditionalFile {
                        path: "build/.attr-1fcgpy7vc4ammr7s17j2xq88scswkgz23dqzc04g8sx5vcp2pppw"
                            .into(),
                        contents: "baz".into(),
                    },
                ],
                working_dir: "build".into(),
                scratch_paths: vec!["build".into(), "nix/store".into()],
                refscan_needles: vec!["pp17lwra2jkx8rha15qabg2q3wij72lj".into()],
            },
            build_request
        );
    }
}
