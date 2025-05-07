use crate::*;
use pretty_assertions::assert_matches;

#[test]
fn test_source_builtin() {
    // Test an evaluation with a source-only builtin. The test ensures
    // that the artificially constructed thunking is correct.

    let eval = Evaluation::builder_pure()
        .add_src_builtin("testSourceBuiltin", "42")
        .build();

    let result = eval.evaluate("builtins.testSourceBuiltin", None);
    assert!(
        result.errors.is_empty(),
        "evaluation failed: {:?}",
        result.errors
    );

    let value = result.value.unwrap();
    assert_matches!(value, Value::Integer(i) if i == 42);
}

#[test]
fn skip_broken_bytecode() {
    let result = Evaluation::builder_pure()
        .build()
        .evaluate(/* code = */ "x", None);

    assert_eq!(result.errors.len(), 1);
    assert_matches!(result.errors[0].kind, ErrorKind::UnknownStaticVariable);
}

/// Checks that deep forcing happens in lexicographic key order
/// See https://cl.snix.dev/c/snix/+/30309/comment/a7c9c6d5_bacf7332/ for
/// details.
#[test]
fn key_order_deep_force() {
    let result = Evaluation::builder_pure().build().evaluate(
        /* code = */
        r#"builtins.toXML {
          c = throw "ccc";
          a = throw "aaa";
          b = throw "bbb";
          d = throw "dd";
        }"#,
        None,
    );
    assert_eq!(result.errors.len(), 1);

    assert_matches!(
        &result.errors[0].kind,
        ErrorKind::CatchableError(CatchableErrorKind::Throw(s)) if s == &NixString::from("aaa")
    );
}
