use std::path::PathBuf;

use clap::Parser;
use tvix_store::utils::ServiceUrlsMemory;

/// Provides a CLI interface to trigger evaluation using tvix-eval.
///
/// Uses configured tvix-[ca]store and tvix-build components,
/// and by default a set of builtins similar to these present in Nix.
///
/// None of the stores available add to the local `/nix/store` location.
///
/// The CLI interface is not stable and subject to change.
#[derive(Parser, Clone)]
pub struct Args {
    /// Path to a script to evaluate
    pub script: Option<PathBuf>,

    #[clap(long, short = 'E')]
    pub expr: Option<String>,

    /// Dump the raw AST to stdout before interpreting
    #[clap(long, env = "TVIX_DISPLAY_AST")]
    pub display_ast: bool,

    /// Dump the bytecode to stdout before evaluating
    #[clap(long, env = "TVIX_DUMP_BYTECODE")]
    pub dump_bytecode: bool,

    /// Trace the runtime of the VM
    #[clap(long, env = "TVIX_TRACE_RUNTIME")]
    pub trace_runtime: bool,

    /// Capture the time (relative to the start time of evaluation) of all events traced with
    /// `--trace-runtime`
    #[clap(long, env = "TVIX_TRACE_RUNTIME_TIMING", requires("trace_runtime"))]
    pub trace_runtime_timing: bool,

    /// Only compile, but do not execute code. This will make Tvix act
    /// sort of like a linter.
    #[clap(long)]
    pub compile_only: bool,

    /// Don't print warnings.
    #[clap(long)]
    pub no_warnings: bool,

    /// Additional entries to the Nix expression search path, a colon-separated list of directories
    /// used to resolve `<...>`-style lookup paths.
    ///
    /// This option may be given multiple times. Paths added through -I take precedence over
    /// NIX_PATH.
    #[clap(long = "extra-nix-path", short = 'I', action = clap::ArgAction::Append)]
    pub extra_nix_paths: Option<Vec<String>>,

    /// Print "raw" (unquoted) output.
    #[clap(long)]
    pub raw: bool,

    /// Strictly evaluate values, traversing them and forcing e.g.
    /// elements of lists and attribute sets before printing the
    /// return value.
    #[clap(long)]
    pub strict: bool,

    #[clap(flatten)]
    pub service_addrs: ServiceUrlsMemory,

    #[arg(long, env, default_value = "dummy://")]
    pub build_service_addr: String,

    /// An optional path in which Derivations encountered during evaluation
    /// are dumped into, after evaluation. If it doesn't exist, the directory is created.
    ///
    /// Files dumped there are named like they would show up in `/nix/store`,
    /// if produced by Nix. Existing files are not overwritten.
    ///
    /// This is only for debugging and diffing purposes for post-eval inspection;
    /// Tvix does not read from these.
    #[clap(long)]
    pub drv_dumpdir: Option<PathBuf>,
}

impl Args {
    pub fn nix_path(&self) -> Option<String> {
        resolve_nix_path(std::env::var("NIX_PATH"), &self.extra_nix_paths)
    }
}

fn resolve_nix_path(
    nix_path: Result<String, std::env::VarError>,
    extra_nix_paths: &Option<Vec<String>>,
) -> Option<String> {
    let nix_path_option = nix_path.ok().filter(|string| !string.is_empty());
    let extra_nix_paths_option = extra_nix_paths.to_owned().map(|vec| vec.join(":"));
    match (nix_path_option, extra_nix_paths_option) {
        (Some(nix_path), Some(mut extra_nix_paths)) => {
            extra_nix_paths.push(':');
            Some(extra_nix_paths + &nix_path)
        }
        (nix_path_option, extra_nix_paths_option) => nix_path_option.or(extra_nix_paths_option),
    }
}

#[cfg(test)]
mod tests {
    use super::resolve_nix_path;

    #[test]
    fn test_resolve_nix_path() {
        let nix_path = Ok("/nixpath1:nixpath2=/nixpath2".to_owned());
        let extra_nix_paths = Some(vec!["/extra1".to_owned(), "extra2=/extra2".to_owned()]);
        let expected = Some("/extra1:extra2=/extra2:/nixpath1:nixpath2=/nixpath2".to_owned());
        let actual = resolve_nix_path(nix_path, &extra_nix_paths);
        assert!(actual == expected);
        let nix_path = Err(std::env::VarError::NotPresent);
        let extra_nix_paths = Some(vec!["/extra1".to_owned(), "extra2=/extra2".to_owned()]);
        let expected = Some("/extra1:extra2=/extra2".to_owned());
        let actual = resolve_nix_path(nix_path, &extra_nix_paths);
        assert!(actual == expected);
        let nix_path = Ok("/nixpath1:nixpath2=/nixpath2".to_owned());
        let extra_nix_paths = None;
        let expected = Some("/nixpath1:nixpath2=/nixpath2".to_owned());
        let actual = resolve_nix_path(nix_path, &extra_nix_paths);
        assert!(actual == expected);
        let nix_path = Err(std::env::VarError::NotPresent);
        let extra_nix_paths = None;
        let expected = None;
        let actual = resolve_nix_path(nix_path, &extra_nix_paths);
        assert!(actual == expected);
    }
}
