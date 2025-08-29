use crate::{EvalIO, FileType, value::Value};
use builtin_macros::builtins;
use pretty_assertions::assert_eq;
use rstest::rstest;
use std::{
    ffi::{OsStr, OsString},
    io::{self},
    path::{Path, PathBuf},
    str::FromStr,
};

#[builtins]
mod mock_builtins {
    //! Builtins which are required by language tests, but should not
    //! actually exist in //snix/eval.
    use crate as snix_eval;
    use crate::generators::GenCo;
    use crate::*;
    use genawaiter::rc::Gen;

    #[builtin("derivation")]
    async fn builtin_derivation(co: GenCo, input: Value) -> Result<Value, ErrorKind> {
        let input = input.to_attrs()?;
        let attrs = input.update(NixAttrs::from_iter(
            [
                (
                    "outPath",
                    "/nix/store/00000000000000000000000000000000-mock",
                ),
                (
                    "drvPath",
                    "/nix/store/00000000000000000000000000000000-mock.drv",
                ),
                ("type", "derivation"),
            ]
            .into_iter(),
        ));

        Ok(Value::Attrs(Box::new(attrs)))
    }
}

struct MockIo<T> {
    // Actual underlying [EvalIO] implementation.
    actual: T,
}

impl<T> MockIo<T> {
    pub fn new(actual: T) -> Self {
        Self { actual }
    }
}

impl<T> EvalIO for MockIo<T>
where
    T: AsRef<dyn EvalIO>,
{
    fn store_dir(&self) -> Option<String> {
        self.actual.as_ref().store_dir()
    }

    fn import_path(&self, path: &Path) -> io::Result<PathBuf> {
        self.actual.as_ref().import_path(path)
    }

    fn path_exists(&self, path: &Path) -> io::Result<bool> {
        self.actual.as_ref().path_exists(path)
    }

    fn open(&self, path: &Path) -> io::Result<Box<dyn io::Read>> {
        self.actual.as_ref().open(path)
    }

    fn file_type(&self, path: &Path) -> io::Result<FileType> {
        self.actual.as_ref().file_type(path)
    }

    fn read_dir(&self, path: &Path) -> io::Result<Vec<(bytes::Bytes, FileType)>> {
        self.actual.as_ref().read_dir(path)
    }

    fn get_env(&self, key: &OsStr) -> Option<OsString> {
        // for eval-okay-getenv.nix
        if key == "TEST_VAR" {
            return Some(OsString::from_str("foo").expect("This conversion is infallible."));
        }

        self.actual.as_ref().get_env(key)
    }
}

#[cfg(feature = "impure")]
fn eval_test(code_path: PathBuf, expect_success: bool) {
    use crate::{StdIO, vm::EvalMode};

    eprintln!("path: {}", code_path.display());
    assert_eq!(
        code_path.extension().unwrap(),
        "nix",
        "test files always end in .nix"
    );

    let code = std::fs::read_to_string(&code_path).expect("should be able to read test code");

    let eval = crate::Evaluation::builder_impure()
        .mode(EvalMode::Strict)
        .io_handle(Box::new(MockIo::new(Box::new(StdIO) as Box<dyn EvalIO>)) as Box<dyn EvalIO>)
        .add_builtins(mock_builtins::builtins())
        .build();

    let result = eval.evaluate(code, Some(code_path.clone()));
    let failed = match result.value {
        Some(Value::Catchable(_)) => true,
        _ => !result.errors.is_empty(),
    };
    if expect_success && failed {
        let error_details = result
            .errors
            .iter()
            .map(|error| error.fancy_format_str())
            .collect::<Vec<String>>();
        let error_string = error_details.join("\n");

        panic!(
            "{}: evaluation of eval-okay test should succeed, but failed with:\n{}",
            code_path.display(),
            error_string,
        );
    }

    if !expect_success && failed {
        return;
    }
    // !expect_success can also mean the output differs, so don't panic if the
    // evaluation didn't fail.

    let value = result.value.unwrap();
    let result_str = value.to_string();

    let exp_path = code_path.with_extension("exp");
    if exp_path.exists() {
        // If there's an .exp file provided alongside, compare it with the
        // output of the NixValue .to_string() method.
        let exp_str = std::fs::read_to_string(&exp_path).expect("unable to read .exp file");

        if expect_success {
            assert_eq!(
                result_str,
                exp_str.trim(),
                "{}: result value representation (left) must match expectation (right)",
                code_path.display()
            );
        } else {
            assert_ne!(
                result_str,
                exp_str.trim(),
                "{}: test passed unexpectedly!  consider moving it out of notyetpassing",
                code_path.display()
            );

            // Early return here, we don't compare .xml outputs if this is a !
            // expect_success test.
            return;
        }
    }

    let exp_xml_path = code_path.with_extension("exp.xml");
    if exp_xml_path.exists() {
        // If there's an XML file provided alongside, compare it with the
        // output produced when serializing the Value as XML.
        let exp_xml_str = std::fs::read_to_string(exp_xml_path).expect("unable to read .xml file");

        let mut xml_actual_buf = Vec::new();
        crate::builtins::value_to_xml(&mut xml_actual_buf, &value).expect("value_to_xml failed");

        assert_eq!(
            String::from_utf8(xml_actual_buf).expect("to_xml produced invalid utf-8"),
            exp_xml_str,
            "{}: result value representation (left) must match expectation (right)",
            code_path.display()
        );
    }
}

// identity-* tests contain Nix code snippets which should evaluate to
// themselves exactly (i.e. literals).
#[cfg(feature = "impure")]
#[rstest]
fn identity(#[files("src/tests/snix_tests/identity-*.nix")] code_path: PathBuf) {
    use crate::{EvalIO, vm::EvalMode};

    let code = std::fs::read_to_string(code_path).expect("should be able to read test code");

    let eval = crate::Evaluation::builder(Box::new(crate::StdIO) as Box<dyn EvalIO>)
        .disable_import()
        .mode(EvalMode::Strict)
        .build();

    let result = eval.evaluate(&code, None);
    assert!(
        result.errors.is_empty(),
        "evaluation of identity test failed: {:?}",
        result.errors
    );

    let result_str = result.value.unwrap().to_string();

    assert_eq!(
        result_str,
        code.trim(),
        "result value representation (left) must match expectation (right)"
    )
}

// eval-okay-* tests contain a snippet of Nix code, and an expectation
// of the produced string output of the evaluator.
//
// These evaluations are always supposed to succeed, i.e. all snippets
// are guaranteed to be valid Nix code.
#[cfg(feature = "impure")]
#[rstest]
fn eval_okay(#[files("src/tests/snix_tests/eval-okay-*.nix")] code_path: PathBuf) {
    eval_test(code_path, true)
}

// eval-okay-* tests from the original Nix test suite.
#[cfg(feature = "impure")]
#[rstest]
fn nix_eval_okay(#[files("src/tests/nix_tests/eval-okay-*.nix")] code_path: PathBuf) {
    eval_test(code_path, true)
}

// eval-okay-* tests from the original Nix test suite which do not yet pass for snix
//
// Eventually there will be none of these left, and this function
// will disappear :)
//
// Please don't submit failing tests unless they're in
// notyetpassing; this makes the test suite much more useful for
// regression testing, since there should always be zero non-ignored
// failing tests.
#[cfg(feature = "impure")]
#[rstest]
fn nix_eval_okay_currently_failing(
    #[files("src/tests/nix_tests/notyetpassing/eval-okay-*.nix")] code_path: PathBuf,
) {
    eval_test(code_path, false)
}

#[cfg(feature = "impure")]
#[rstest]
fn eval_okay_currently_failing(
    #[files("src/tests/snix_tests/notyetpassing/eval-okay-*.nix")] code_path: PathBuf,
) {
    eval_test(code_path, false)
}

// eval-fail-* tests contain a snippet of Nix code, which is
// expected to fail evaluation.  The exact type of failure
// (assertion, parse error, etc) is not currently checked.
#[cfg(feature = "impure")]
#[rstest]
fn eval_fail(#[files("src/tests/snix_tests/eval-fail-*.nix")] code_path: PathBuf) {
    eval_test(code_path, false)
}

// eval-fail-* tests from the original Nix test suite.
#[cfg(feature = "impure")]
#[rstest]
fn nix_eval_fail(#[files("src/tests/nix_tests/eval-fail-*.nix")] code_path: PathBuf) {
    eval_test(code_path, false)
}
