use std::{rc::Rc, sync::Arc};

use clap::Parser;
use pretty_assertions::assert_eq;
use snix_build::buildservice::DummyBuildService;
use snix_eval::{EvalIO, EvalMode, Value};
use snix_store::utils::{ServiceUrlsMemory, construct_services};
use std::path::PathBuf;

use rstest::rstest;

use crate::{
    builtins::{add_derivation_builtins, add_fetcher_builtins, add_import_builtins},
    configure_nix_path,
    snix_io::SnixIO,
    snix_store_io::SnixStoreIO,
};

fn eval_test(code_path: PathBuf, expect_success: bool) {
    assert_eq!(
        code_path.extension().unwrap(),
        "nix",
        "test files always end in .nix"
    );
    let code = std::fs::read_to_string(&code_path).expect("should be able to read test code");

    let tokio_runtime = tokio::runtime::Runtime::new().unwrap();
    let (blob_service, directory_service, path_info_service, nar_calculation_service) =
        tokio_runtime
            .block_on(async {
                construct_services(ServiceUrlsMemory::parse_from(std::iter::empty::<&str>())).await
            })
            .unwrap();

    let snix_store_io = Rc::new(SnixStoreIO::new(
        blob_service,
        directory_service,
        path_info_service,
        nar_calculation_service.into(),
        Arc::new(DummyBuildService::default()),
        tokio_runtime.handle().clone(),
        Vec::new(),
    ));
    // Wrap with SnixIO, so <nix/fetchurl.nix can be imported.
    let mut eval_builder = snix_eval::Evaluation::builder(Box::new(SnixIO::new(
        snix_store_io.clone() as Rc<dyn EvalIO>,
    )) as Box<dyn EvalIO>)
    .enable_import()
    .mode(EvalMode::Strict);

    eval_builder = add_derivation_builtins(eval_builder, Rc::clone(&snix_store_io));
    eval_builder = add_fetcher_builtins(eval_builder, Rc::clone(&snix_store_io));
    eval_builder = add_import_builtins(eval_builder, snix_store_io);
    eval_builder = configure_nix_path(eval_builder, &None);

    let eval = eval_builder.build();

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
        snix_eval::builtins::value_to_xml(&mut xml_actual_buf, &value)
            .expect("value_to_xml failed");

        assert_eq!(
            String::from_utf8(xml_actual_buf).expect("to_xml produced invalid utf-8"),
            exp_xml_str,
            "{}: result value representation (left) must match expectation (right)",
            code_path.display()
        );
    }
}

// eval-okay-* tests contain a snippet of Nix code, and an expectation
// of the produced string output of the evaluator.
//
// These evaluations are always supposed to succeed, i.e. all snippets
// are guaranteed to be valid Nix code.
#[rstest]
fn eval_okay(#[files("src/tests/snix_tests/eval-okay-*.nix")] code_path: PathBuf) {
    eval_test(code_path, true)
}

// eval-okay-* tests from the original Nix test suite.
#[cfg(feature = "nix_tests")]
#[rstest]
fn nix_eval_okay(#[files("src/tests/nix_tests/eval-okay-*.nix")] code_path: PathBuf) {
    eval_test(code_path, true)
}

// eval-okay-* tests from the original Nix test suite which do not yet pass for snix
//
// Eventually there will be none of these left, and this function
// will disappear :) Until then, to run these tests, use `cargo test
// --features expected_failures`.
//
// Please don't submit failing tests unless they're in
// notyetpassing; this makes the test suite much more useful for
// regression testing, since there should always be zero non-ignored
// failing tests.
//
// NOTE: There's no such test anymore. `rstest` does not handle empty directories, so, we
// just comment it for now.
//
// #[rstest]
// fn nix_eval_okay_currently_failing(
//     #[files("src/tests/nix_tests/notyetpassing/eval-okay-*.nix")] code_path: PathBuf,
// ) {
//     eval_test(code_path, false)
// }

// eval-fail-* tests contain a snippet of Nix code, which is
// expected to fail evaluation.  The exact type of failure
// (assertion, parse error, etc) is not currently checked.
#[rstest]
fn eval_fail(#[files("src/tests/snix_tests/eval-fail-*.nix")] code_path: PathBuf) {
    eval_test(code_path, false)
}
