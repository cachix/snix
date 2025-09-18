//! This module implements the builtins exposed in the Nix language.
//!
//! See //snix/eval/docs/builtins.md for a some context on the
//! available builtins in Nix.

use bstr::{ByteSlice, ByteVec};
use builtin_macros::builtins;
use genawaiter::rc::Gen;
use regex::Regex;
use rustc_hash::FxHashMap;
use std::cell::RefCell;
use std::cmp::{self, Ordering};
use std::collections::BTreeMap;
use std::collections::VecDeque;
use std::collections::hash_map::Entry;
use std::path::PathBuf;
use std::rc::Rc;

use crate::value::PointerEquality;
use crate::vm::generators::{self, GenCo};
use crate::warnings::WarningKind;
use crate::{
    self as snix_eval,
    builtins::hash::hash_nix_string,
    errors::{CatchableErrorKind, ErrorKind},
    value::{CoercionKind, NixAttrs, NixList, NixString, Thunk, Value},
};
use crate::{arithmetic_op, try_cek};

use self::versions::{VersionPart, VersionPartsIter};

mod hash;
mod to_xml;
mod versions;

// technically #[cfg(test)], but right now we need it for tests in other crates…
pub use to_xml::value_to_xml;

#[cfg(feature = "impure")]
mod impure;

#[cfg(feature = "impure")]
pub use impure::impure_builtins;

// we set SNIX_CURRENT_SYSTEM in build.rs
pub const CURRENT_PLATFORM: &str = env!("SNIX_CURRENT_SYSTEM");

/// Coerce a Nix Value to a plain path, e.g. in order to access the
/// file it points to via either `builtins.toPath` or an impure
/// builtin. This coercion can _never_ be performed in a Nix program
/// without using builtins (i.e. the trick `path: /. + path` to
/// convert from a string to a path wouldn't hit this code).
///
/// This operation doesn't import a Nix path value into the store.
pub async fn coerce_value_to_path(
    co: &GenCo,
    v: Value,
) -> Result<Result<PathBuf, CatchableErrorKind>, ErrorKind> {
    let value = generators::request_force(co, v).await;
    if let Value::Path(p) = value {
        return Ok(Ok(*p));
    }

    let vs = try_cek!(
        generators::request_string_coerce(
            co,
            value,
            CoercionKind {
                strong: false,
                import_paths: false,
            },
        )
        .await
    );

    let path = vs.to_path()?.to_owned();
    if path.is_absolute() {
        Ok(Ok(path))
    } else {
        Err(ErrorKind::NotAnAbsolutePath(path))
    }
}

#[derive(Debug, Default)]
struct BuiltinState {
    regex_cache: RefCell<FxHashMap<String, Regex>>,
}

impl BuiltinState {
    fn get_regex(&self, pattern: &str) -> Result<Regex, regex::Error> {
        let mut map = self.regex_cache.borrow_mut();
        Ok(match map.entry(pattern.to_string()) {
            Entry::Occupied(occupied) => occupied.get().clone(),
            Entry::Vacant(vacant) => {
                let re = Regex::new(pattern)?;
                vacant.insert(re).clone()
            }
        })
    }
}

#[builtins(state = "Rc<BuiltinState>")]
mod pure_builtins {
    use std::ffi::OsString;

    use bstr::{B, BString, ByteSlice};
    use itertools::Itertools;
    use os_str_bytes::OsStringBytes;
    use rustc_hash::{FxHashMap, FxHashSet};

    use crate::{
        AddContext, NixContext, NixContextElement, try_cek_to_value, value::PointerEquality,
    };

    use super::*;

    macro_rules! try_value {
        ($value:expr) => {{
            let val = $value;
            if val.is_catchable() {
                return Ok(val);
            }
            val
        }};
    }

    #[builtin("abort")]
    async fn builtin_abort(co: GenCo, message: Value) -> Result<Value, ErrorKind> {
        // TODO(sterni): coerces to string
        // Although `abort` does not make use of any context,
        // we must still accept contextful strings as parameters.
        // If `to_str` was used, this would err out with an unexpected type error.
        // Therefore, we explicitly accept contextful strings and ignore their contexts.
        Err(ErrorKind::Abort(message.to_contextful_str()?.to_string()))
    }

    #[builtin("add")]
    async fn builtin_add(co: GenCo, x: Value, y: Value) -> Result<Value, ErrorKind> {
        arithmetic_op!(&x, &y, +)
    }

    #[builtin("all")]
    async fn builtin_all(co: GenCo, pred: Value, list: Value) -> Result<Value, ErrorKind> {
        for value in list.to_list()?.into_iter() {
            let pred_result = generators::request_call_with(&co, pred.clone(), [value]).await;
            let pred_result = try_value!(generators::request_force(&co, pred_result).await);

            if !pred_result.as_bool()? {
                return Ok(Value::Bool(false));
            }
        }

        Ok(Value::Bool(true))
    }

    #[builtin("any")]
    async fn builtin_any(co: GenCo, pred: Value, list: Value) -> Result<Value, ErrorKind> {
        for value in list.to_list()?.into_iter() {
            let pred_result = generators::request_call_with(&co, pred.clone(), [value]).await;
            let pred_result = try_value!(generators::request_force(&co, pred_result).await);

            if pred_result.as_bool()? {
                return Ok(Value::Bool(true));
            }
        }

        Ok(Value::Bool(false))
    }

    #[builtin("attrNames")]
    async fn builtin_attr_names(co: GenCo, set: Value) -> Result<Value, ErrorKind> {
        let xs = set.to_attrs()?;
        let mut output = Vec::with_capacity(xs.len());

        for (key, _val) in xs.iter_sorted() {
            output.push(Value::from(key.clone()));
        }

        Ok(Value::List(NixList::construct(output.len(), output)))
    }

    #[builtin("attrValues")]
    async fn builtin_attr_values(co: GenCo, set: Value) -> Result<Value, ErrorKind> {
        let xs = set.to_attrs()?;
        let mut output = Vec::with_capacity(xs.len());

        for (_key, val) in xs.iter_sorted() {
            output.push(val.clone());
        }

        Ok(Value::List(NixList::construct(output.len(), output)))
    }

    #[builtin("baseNameOf")]
    async fn builtin_base_name_of(co: GenCo, s: Value) -> Result<Value, ErrorKind> {
        let span = generators::request_span(&co).await;
        let s = s
            .coerce_to_string(
                co,
                CoercionKind {
                    strong: false,
                    import_paths: false,
                },
                span,
            )
            .await?
            .to_contextful_str()?;

        let mut bs = (**s).to_owned();
        if let Some(last_slash) = bs.rfind_char('/') {
            bs = bs[(last_slash + 1)..].into();
        }
        Ok(NixString::new_inherit_context_from(&s, bs).into())
    }

    #[builtin("bitAnd")]
    async fn builtin_bit_and(co: GenCo, x: Value, y: Value) -> Result<Value, ErrorKind> {
        Ok(Value::Integer(x.as_int()? & y.as_int()?))
    }

    #[builtin("bitOr")]
    async fn builtin_bit_or(co: GenCo, x: Value, y: Value) -> Result<Value, ErrorKind> {
        Ok(Value::Integer(x.as_int()? | y.as_int()?))
    }

    #[builtin("bitXor")]
    async fn builtin_bit_xor(co: GenCo, x: Value, y: Value) -> Result<Value, ErrorKind> {
        Ok(Value::Integer(x.as_int()? ^ y.as_int()?))
    }

    #[builtin("catAttrs")]
    async fn builtin_cat_attrs(co: GenCo, key: Value, list: Value) -> Result<Value, ErrorKind> {
        let key = key.to_str()?;
        let list = list.to_list()?;
        let mut output = vec![];

        for item in list.into_iter() {
            let set = generators::request_force(&co, item).await.to_attrs()?;

            if let Some(value) = set.select(&key) {
                output.push(value.clone());
            }
        }

        Ok(Value::List(NixList::construct(output.len(), output)))
    }

    #[builtin("ceil")]
    async fn builtin_ceil(co: GenCo, double: Value) -> Result<Value, ErrorKind> {
        Ok(Value::Integer(double.as_float()?.ceil() as i64))
    }

    #[builtin("compareVersions")]
    async fn builtin_compare_versions(co: GenCo, x: Value, y: Value) -> Result<Value, ErrorKind> {
        let s1 = x.to_str()?;
        let s1 = VersionPartsIter::new_for_cmp((&s1).into());
        let s2 = y.to_str()?;
        let s2 = VersionPartsIter::new_for_cmp((&s2).into());

        match s1.cmp(s2) {
            std::cmp::Ordering::Less => Ok(Value::Integer(-1)),
            std::cmp::Ordering::Equal => Ok(Value::Integer(0)),
            std::cmp::Ordering::Greater => Ok(Value::Integer(1)),
        }
    }

    #[builtin("concatLists")]
    async fn builtin_concat_lists(co: GenCo, lists: Value) -> Result<Value, ErrorKind> {
        let mut out = Vec::new();

        for value in lists.to_list()? {
            let list = try_value!(generators::request_force(&co, value).await).to_list()?;
            out.extend(list.into_iter());
        }

        Ok(Value::List(out.into()))
    }

    #[builtin("concatMap")]
    async fn builtin_concat_map(co: GenCo, f: Value, list: Value) -> Result<Value, ErrorKind> {
        let list = list.to_list()?;
        let mut res = Vec::new();
        for val in list {
            let out = generators::request_call_with(&co, f.clone(), [val]).await;
            let out = try_value!(generators::request_force(&co, out).await);
            res.extend(out.to_list()?);
        }
        Ok(Value::List(res.into()))
    }

    #[builtin("concatStringsSep")]
    async fn builtin_concat_strings_sep(
        co: GenCo,
        separator: Value,
        list: Value,
    ) -> Result<Value, ErrorKind> {
        let mut separator = separator.to_contextful_str()?;

        let mut context = NixContext::new();
        if let Some(sep_context) = separator.take_context() {
            context.extend(sep_context.into_iter())
        }
        let list = list.to_list()?;
        let mut res = BString::default();
        for (i, val) in list.into_iter().enumerate() {
            if i != 0 {
                res.push_str(&separator);
            }
            let mut s = try_cek_to_value!(
                generators::request_string_coerce(
                    &co,
                    val,
                    CoercionKind {
                        strong: false,
                        import_paths: true,
                    },
                )
                .await
            );
            res.push_str(&s);
            if let Some(other_context) = s.take_context() {
                context.extend(other_context.into_iter());
            }
        }
        // FIXME: pass immediately the string res.
        Ok(NixString::new_context_from(context, res).into())
    }

    #[builtin("deepSeq")]
    async fn builtin_deep_seq(co: GenCo, x: Value, y: Value) -> Result<Value, ErrorKind> {
        generators::request_deep_force(&co, x).await;
        Ok(y)
    }

    #[builtin("div")]
    async fn builtin_div(co: GenCo, x: Value, y: Value) -> Result<Value, ErrorKind> {
        arithmetic_op!(&x, &y, /)
    }

    #[builtin("dirOf")]
    async fn builtin_dir_of(co: GenCo, s: Value) -> Result<Value, ErrorKind> {
        let is_path = s.is_path();
        let span = generators::request_span(&co).await;
        let str = s
            .coerce_to_string(
                co,
                CoercionKind {
                    strong: false,
                    import_paths: false,
                },
                span,
            )
            .await?
            .to_contextful_str()?;
        let result = str
            .rfind_char('/')
            .map(|last_slash| {
                let x = &str[..last_slash];
                if x.is_empty() { B("/") } else { x }
            })
            .unwrap_or(b".");
        if is_path {
            Ok(Value::Path(Box::new(PathBuf::from(
                OsString::assert_from_raw_vec(result.to_owned()),
            ))))
        } else {
            Ok(Value::from(NixString::new_inherit_context_from(
                &str, result,
            )))
        }
    }

    #[builtin("elem")]
    async fn builtin_elem(co: GenCo, x: Value, xs: Value) -> Result<Value, ErrorKind> {
        for val in xs.to_list()? {
            match try_cek_to_value!(
                generators::check_equality(&co, x.clone(), val, PointerEquality::AllowAll).await?
            ) {
                true => return Ok(true.into()),
                false => continue,
            }
        }
        Ok(false.into())
    }

    #[builtin("elemAt")]
    async fn builtin_elem_at(co: GenCo, xs: Value, i: Value) -> Result<Value, ErrorKind> {
        let xs = xs.to_list()?;
        let i = i.as_int()?;
        if i < 0 {
            Err(ErrorKind::IndexOutOfBounds { index: i })
        } else {
            match xs.get(i as usize) {
                Some(x) => Ok(x.clone()),
                None => Err(ErrorKind::IndexOutOfBounds { index: i }),
            }
        }
    }

    #[builtin("filter")]
    async fn builtin_filter(co: GenCo, pred: Value, list: Value) -> Result<Value, ErrorKind> {
        let list: NixList = list.to_list()?;
        let mut out = Vec::new();

        for value in list {
            let result = generators::request_call_with(&co, pred.clone(), [value.clone()]).await;
            let verdict = try_value!(generators::request_force(&co, result).await);
            if verdict.as_bool()? {
                out.push(value);
            }
        }

        Ok(Value::List(out.into()))
    }

    #[builtin("floor")]
    async fn builtin_floor(co: GenCo, double: Value) -> Result<Value, ErrorKind> {
        Ok(Value::Integer(double.as_float()?.floor() as i64))
    }

    #[builtin("foldl'")]
    async fn builtin_foldl(
        co: GenCo,
        op: Value,
        #[lazy] nul: Value,
        list: Value,
    ) -> Result<Value, ErrorKind> {
        let mut nul = nul;
        let list = list.to_list()?;
        for val in list {
            // Every call of `op` is forced immediately, but `nul` is not, see
            // https://github.com/NixOS/nix/blob/940e9eb8/src/libexpr/primops.cc#L3069-L3070C36
            // and our tests for foldl'.
            nul = generators::request_call_with(&co, op.clone(), [nul, val]).await;
            nul = generators::request_force(&co, nul).await;
            if let c @ Value::Catchable(_) = nul {
                return Ok(c);
            }
        }

        Ok(nul)
    }

    #[builtin("functionArgs")]
    async fn builtin_function_args(co: GenCo, f: Value) -> Result<Value, ErrorKind> {
        let lambda = &f.as_closure()?.lambda();
        let formals = if let Some(formals) = &lambda.formals {
            formals
        } else {
            return Ok(Value::attrs(NixAttrs::empty()));
        };
        Ok(Value::attrs(NixAttrs::from_iter(
            formals.arguments.iter().map(|(k, v)| (k.clone(), (*v))),
        )))
    }

    #[builtin("fromJSON")]
    async fn builtin_from_json(co: GenCo, json: Value) -> Result<Value, ErrorKind> {
        let json_str = json.to_str()?;
        serde_json::from_slice(&json_str).map_err(|err| err.into())
    }

    #[builtin("toJSON")]
    async fn builtin_to_json(co: GenCo, val: Value) -> Result<Value, ErrorKind> {
        match val.into_contextful_json(&co).await {
            Err(ErrorKind::CatchableError(catchable)) => Ok(Value::Catchable(Box::new(catchable))),
            Err(err) => Err(err),
            Ok((json, context)) => {
                let json_str = serde_json::to_string(&json)
                    .map_err(|err| ErrorKind::JsonError(err.to_string()))?;
                Ok(Value::String(NixString::new_context_from(
                    context, json_str,
                )))
            }
        }
    }

    #[builtin("fromTOML")]
    async fn builtin_from_toml(co: GenCo, toml: Value) -> Result<Value, ErrorKind> {
        let toml_str = toml.to_str()?;

        toml::from_str(toml_str.to_str()?).map_err(|err| err.into())
    }

    #[builtin("genericClosure")]
    async fn builtin_generic_closure(co: GenCo, input: Value) -> Result<Value, ErrorKind> {
        let attrs = input.to_attrs()?;

        // The work set is maintained as a VecDeque because new items
        // are popped from the front.
        let mut work_set: VecDeque<Value> =
            generators::request_force(&co, attrs.select_required("startSet")?.clone())
                .await
                .to_list()?
                .into_iter()
                .collect();

        let operator = attrs.select_required("operator")?;

        let mut res = Vec::new();
        let mut done_keys: Vec<Value> = vec![];

        while let Some(val) = work_set.pop_front() {
            let val = generators::request_force(&co, val).await;
            let attrs = val.to_attrs()?;
            let key = attrs.select_required("key")?;

            let value_missing =
                try_cek_to_value!(bgc_insert_key(&co, key.clone(), &mut done_keys).await?);

            if !value_missing {
                continue;
            }

            res.push(val.clone());

            let op_result = generators::request_force(
                &co,
                generators::request_call_with(&co, operator.clone(), [val]).await,
            )
            .await;

            work_set.extend(op_result.to_list()?.into_iter());
        }

        Ok(Value::List(NixList::from(res)))
    }

    #[builtin("genList")]
    async fn builtin_gen_list(
        co: GenCo,
        // Nix 2.3 doesn't propagate failures here
        #[lazy] generator: Value,
        length: Value,
    ) -> Result<Value, ErrorKind> {
        let len = length.as_int()?;
        let mut out = Vec::with_capacity(
            len.try_into()
                .map_err(|_| ErrorKind::Abort(format!("can not create list of size {len}")))?,
        );

        // the best span we can get…
        let span = generators::request_span(&co).await;

        for i in 0..len {
            let val = Value::Thunk(Thunk::new_suspended_call(generator.clone(), i.into(), span));
            out.push(val);
        }

        Ok(Value::List(out.into()))
    }

    #[builtin("getAttr")]
    async fn builtin_get_attr(co: GenCo, key: Value, set: Value) -> Result<Value, ErrorKind> {
        let k = key.to_str()?;
        let xs = set.to_attrs()?;

        match xs.select(&k) {
            Some(x) => Ok(x.clone()),
            None => Err(ErrorKind::AttributeNotFound {
                name: k.to_string(),
            }),
        }
    }

    #[builtin("groupBy")]
    async fn builtin_group_by(co: GenCo, f: Value, list: Value) -> Result<Value, ErrorKind> {
        let mut res: BTreeMap<NixString, Vec<Value>> = BTreeMap::new();
        for val in list.to_list()? {
            let key = try_value!(
                generators::request_force(
                    &co,
                    generators::request_call_with(&co, f.clone(), [val.clone()]).await,
                )
                .await
            )
            .to_str()?;

            res.entry(key).or_default().push(val);
        }
        Ok(Value::attrs(NixAttrs::from_iter(
            res.into_iter()
                .map(|(k, v)| (k, Value::List(NixList::from(v)))),
        )))
    }

    #[builtin("hasAttr")]
    async fn builtin_has_attr(co: GenCo, key: Value, set: Value) -> Result<Value, ErrorKind> {
        let k = key.to_str()?;
        let xs = set.to_attrs()?;

        Ok(Value::Bool(xs.contains(&k)))
    }

    #[builtin("hasContext")]
    #[allow(non_snake_case)]
    async fn builtin_hasContext(co: GenCo, e: Value) -> Result<Value, ErrorKind> {
        if e.is_catchable() {
            return Ok(e);
        }

        let v = e.to_contextful_str()?;
        Ok(Value::Bool(v.has_context()))
    }

    #[builtin("getContext")]
    #[allow(non_snake_case)]
    async fn builtin_getContext(co: GenCo, e: Value) -> Result<Value, ErrorKind> {
        if e.is_catchable() {
            return Ok(e);
        }

        // also forces the value
        let span = generators::request_span(&co).await;
        let v = e
            .coerce_to_string(
                co,
                CoercionKind {
                    strong: true,
                    import_paths: true,
                },
                span,
            )
            .await?;
        let s = v.to_contextful_str()?;

        let groups = s
            .iter_context()
            .flat_map(|context| context.iter())
            // Do not think `group_by` works here.
            // `group_by` works on consecutive elements of the iterator.
            // Due to how `HashSet` works (ordering is not guaranteed),
            // this can become a source of non-determinism if you `group_by` naively.
            // I know I did.
            .into_grouping_map_by(|ctx_element| match ctx_element {
                NixContextElement::Plain(spath) => spath,
                NixContextElement::Single { derivation, .. } => derivation,
                NixContextElement::Derivation(drv_path) => drv_path,
            })
            .collect::<Vec<_>>();

        let elements = groups
            .into_iter()
            .map(|(key, group)| {
                let mut outputs: Vec<NixString> = Vec::new();
                let mut is_path = false;
                let mut all_outputs = false;

                for ctx_element in group {
                    match ctx_element {
                        NixContextElement::Plain(spath) => {
                            debug_assert!(spath == key, "Unexpected group containing mixed keys, expected: {key:?}, encountered {spath:?}");
                            is_path = true;
                        }

                        NixContextElement::Single { name, derivation } => {
                            debug_assert!(derivation == key, "Unexpected group containing mixed keys, expected: {key:?}, encountered {derivation:?}");
                            outputs.push(name.clone().into());
                        }

                        NixContextElement::Derivation(drv_path) => {
                            debug_assert!(drv_path == key, "Unexpected group containing mixed keys, expected: {key:?}, encountered {drv_path:?}");
                            all_outputs = true;
                        }
                    }
                }

                // FIXME(raitobezarius): is there a better way to construct an attribute set
                // conditionally?
                let mut vec_attrs: Vec<(&str, Value)> = Vec::new();

                if is_path {
                    vec_attrs.push(("path", true.into()));
                }

                if all_outputs {
                    vec_attrs.push(("allOutputs", true.into()));
                }

                if !outputs.is_empty() {
                    outputs.sort();
                    vec_attrs.push(("outputs", Value::List(outputs
                                .into_iter()
                                .map(|s| s.into())
                                .collect::<Vec<Value>>()
                                .into()
                    )));
                }

                (key.clone(), Value::attrs(NixAttrs::from_iter(vec_attrs.into_iter())))
            });

        Ok(Value::attrs(NixAttrs::from_iter(elements)))
    }

    #[builtin("appendContext")]
    #[allow(non_snake_case)]
    async fn builtin_appendContext(
        co: GenCo,
        origin: Value,
        added_context: Value,
    ) -> Result<Value, ErrorKind> {
        // `appendContext` is a "grow" context function.
        // It cannot remove a context element, neither replace a piece of its contents.
        //
        // Growing context is always a safe operation, there's no loss of dependency tracking
        // information.
        //
        // This is why this operation is not prefixed by `unsafe` and is deemed *safe*.
        // Nonetheless, it is possible to craft nonsensical context elements referring
        // to inexistent derivations, output paths or output names.
        //
        // In Nix, those nonsensical context elements are partially mitigated by checking
        // that various parameters are indeed syntatically valid store paths in the context, i.e.
        // starting with the same prefix as `builtins.storeDir`, or ending with `.drv`.
        // In addition, if writing to the store is possible (evaluator not in read-only mode), Nix
        // will realize some paths and ensures they are present in the store.
        //
        // In this implementation, we do none of that, no syntax checks, no realization.
        // The next `TODO` are the checks that Nix implements.
        let mut ctx_elements: FxHashSet<NixContextElement> = FxHashSet::default();
        let span = generators::request_span(&co).await;
        let origin = origin
            .coerce_to_string(
                co,
                CoercionKind {
                    strong: true,
                    import_paths: true,
                },
                span,
            )
            .await?;
        let mut origin = origin.to_contextful_str()?;

        let added_context = added_context.to_attrs()?;
        for (context_key, context_element) in added_context.into_iter() {
            // Invariant checks:
            // - TODO: context_key must be a syntactically valid store path.
            // - Perform a deep force `context_element`.
            let context_element = context_element.to_attrs()?;
            if let Some(path) = context_element.select("path") {
                if path.as_bool()? {
                    ctx_elements.insert(NixContextElement::Plain(context_key.to_string()));
                }
            }
            if let Some(all_outputs) = context_element.select("allOutputs") {
                if all_outputs.as_bool()? {
                    // TODO: check if `context_key` is a derivation path.
                    // This may require realization.
                    ctx_elements.insert(NixContextElement::Derivation(context_key.to_string()));
                }
            }
            if let Some(some_outputs) = context_element.select("outputs") {
                let some_outputs = some_outputs.to_list()?;
                // TODO: check if `context_key` is a derivation path.
                // This may require realization.
                for output in some_outputs.into_iter() {
                    let output = output.to_str()?;
                    ctx_elements.insert(NixContextElement::Single {
                        derivation: context_key.to_string(),
                        name: output.to_string(),
                    });
                }
            }
        }

        if let Some(origin_ctx) = origin.context_mut() {
            origin_ctx.extend(ctx_elements)
            // TODO: didn't we forget cases where origin had no context?
        }

        Ok(origin.into())
    }

    #[builtin("hashString")]
    async fn builtin_hash_string(co: GenCo, algo: Value, s: Value) -> Result<Value, ErrorKind> {
        hash_nix_string(algo.to_str()?, std::io::Cursor::new(s.to_str()?)).map(Value::from)
    }

    #[builtin("head")]
    async fn builtin_head(co: GenCo, list: Value) -> Result<Value, ErrorKind> {
        if list.is_catchable() {
            return Ok(list);
        }

        match list.to_list()?.get(0) {
            Some(x) => Ok(x.clone()),
            None => Err(ErrorKind::IndexOutOfBounds { index: 0 }),
        }
    }

    #[builtin("intersectAttrs")]
    async fn builtin_intersect_attrs(co: GenCo, x: Value, y: Value) -> Result<Value, ErrorKind> {
        if x.is_catchable() {
            return Ok(x);
        }
        if y.is_catchable() {
            return Ok(y);
        }
        let left_set = x.to_attrs()?;
        if left_set.is_empty() {
            return Ok(Value::attrs(NixAttrs::empty()));
        }

        let right_set = y.to_attrs()?;

        if right_set.is_empty() {
            return Ok(Value::attrs(NixAttrs::empty()));
        }

        Ok(Value::attrs(left_set.intersect(&right_set)))
    }

    #[builtin("isAttrs")]
    async fn builtin_is_attrs(co: GenCo, value: Value) -> Result<Value, ErrorKind> {
        // TODO(edef): make this beautiful
        if value.is_catchable() {
            return Ok(value);
        }

        Ok(Value::Bool(matches!(value, Value::Attrs(_))))
    }

    #[builtin("isBool")]
    async fn builtin_is_bool(co: GenCo, value: Value) -> Result<Value, ErrorKind> {
        if value.is_catchable() {
            return Ok(value);
        }

        Ok(Value::Bool(matches!(value, Value::Bool(_))))
    }

    #[builtin("isFloat")]
    async fn builtin_is_float(co: GenCo, value: Value) -> Result<Value, ErrorKind> {
        if value.is_catchable() {
            return Ok(value);
        }

        Ok(Value::Bool(matches!(value, Value::Float(_))))
    }

    #[builtin("isFunction")]
    async fn builtin_is_function(co: GenCo, value: Value) -> Result<Value, ErrorKind> {
        if value.is_catchable() {
            return Ok(value);
        }

        Ok(Value::Bool(matches!(
            value,
            Value::Closure(_) | Value::Builtin(_)
        )))
    }

    #[builtin("isInt")]
    async fn builtin_is_int(co: GenCo, value: Value) -> Result<Value, ErrorKind> {
        if value.is_catchable() {
            return Ok(value);
        }

        Ok(Value::Bool(matches!(value, Value::Integer(_))))
    }

    #[builtin("isList")]
    async fn builtin_is_list(co: GenCo, value: Value) -> Result<Value, ErrorKind> {
        if value.is_catchable() {
            return Ok(value);
        }

        Ok(Value::Bool(matches!(value, Value::List(_))))
    }

    #[builtin("isNull")]
    async fn builtin_is_null(co: GenCo, value: Value) -> Result<Value, ErrorKind> {
        if value.is_catchable() {
            return Ok(value);
        }

        Ok(Value::Bool(matches!(value, Value::Null)))
    }

    #[builtin("isPath")]
    async fn builtin_is_path(co: GenCo, value: Value) -> Result<Value, ErrorKind> {
        if value.is_catchable() {
            return Ok(value);
        }

        Ok(Value::Bool(matches!(value, Value::Path(_))))
    }

    #[builtin("isString")]
    async fn builtin_is_string(co: GenCo, value: Value) -> Result<Value, ErrorKind> {
        if value.is_catchable() {
            return Ok(value);
        }

        Ok(Value::Bool(matches!(value, Value::String(_))))
    }

    #[builtin("length")]
    async fn builtin_length(co: GenCo, list: Value) -> Result<Value, ErrorKind> {
        if list.is_catchable() {
            return Ok(list);
        }
        Ok(Value::Integer(list.to_list()?.len() as i64))
    }

    #[builtin("lessThan")]
    async fn builtin_less_than(co: GenCo, x: Value, y: Value) -> Result<Value, ErrorKind> {
        let span = generators::request_span(&co).await;
        match try_cek_to_value!(x.nix_cmp_ordering(y, co, span).await?) {
            Ordering::Less => Ok(Value::Bool(true)),
            _ => Ok(Value::Bool(false)),
        }
    }

    #[builtin("listToAttrs")]
    async fn builtin_list_to_attrs(co: GenCo, list: Value) -> Result<Value, ErrorKind> {
        let list = list.to_list()?;
        let mut map = FxHashMap::default();
        for val in list {
            let attrs = try_value!(generators::request_force(&co, val).await).to_attrs()?;
            let name = try_value!(
                generators::request_force(&co, attrs.select_required("name")?.clone()).await
            )
            .to_str()?;
            let value = attrs.select_required("value")?.clone();
            // Map entries earlier in the list take precedence over entries later in the list
            map.entry(name).or_insert(value);
        }
        Ok(Value::attrs(NixAttrs::from(map)))
    }

    #[builtin("map")]
    async fn builtin_map(co: GenCo, #[lazy] f: Value, list_val: Value) -> Result<Value, ErrorKind> {
        let list = list_val.to_list()?;
        let mut out = Vec::with_capacity(list.len());

        // the best span we can get…
        let span = generators::request_span(&co).await;

        for val in list {
            let result = Value::Thunk(Thunk::new_suspended_call(f.clone(), val, span));
            out.push(result)
        }

        Ok(Value::List(out.into()))
    }

    #[builtin("mapAttrs")]
    async fn builtin_map_attrs(
        co: GenCo,
        #[lazy] f: Value,
        attrs: Value,
    ) -> Result<Value, ErrorKind> {
        let attrs = attrs.to_attrs()?;
        let mut out = FxHashMap::default();

        // the best span we can get…
        let span = generators::request_span(&co).await;

        for (key, value) in attrs.into_iter() {
            let result = Value::Thunk(Thunk::new_suspended_call(
                f.clone(),
                key.clone().into(),
                span,
            ));
            let result = Value::Thunk(Thunk::new_suspended_call(result, value, span));

            out.insert(key, result);
        }

        Ok(Value::attrs(out.into()))
    }

    #[builtin("match")]
    async fn builtin_match(
        state: Rc<BuiltinState>,
        co: GenCo,
        regex: Value,
        str: Value,
    ) -> Result<Value, ErrorKind> {
        let s = str;
        if s.is_catchable() {
            return Ok(s);
        }
        let s = s.to_contextful_str()?;
        let re = regex;
        if re.is_catchable() {
            return Ok(re);
        }
        let re = re.to_str()?;
        let re = re.to_str()?;
        let re = state
            .get_regex(&format!("^{re}$"))
            .map_err(|_| ErrorKind::InvalidRegex(re.to_string()))?;

        match re.captures(s.to_str()?) {
            Some(caps) => Ok(Value::List(
                caps.iter()
                    .skip(1)
                    .map(|grp| {
                        // Surprisingly, Nix does not propagate
                        // the original context here.
                        // Though, it accepts contextful strings as an argument.
                        // An example of such behaviors in nixpkgs
                        // can be observed in make-initrd.nix when it comes
                        // to compressors which are matched over their full command
                        // and then a compressor name will be extracted from that.
                        grp.map(|g| Value::from(g.as_str())).unwrap_or(Value::Null)
                    })
                    .collect::<Vec<Value>>()
                    .into(),
            )),
            None => Ok(Value::Null),
        }
    }

    #[builtin("mul")]
    async fn builtin_mul(co: GenCo, x: Value, y: Value) -> Result<Value, ErrorKind> {
        arithmetic_op!(&x, &y, *)
    }

    #[builtin("parseDrvName")]
    async fn builtin_parse_drv_name(co: GenCo, s: Value) -> Result<Value, ErrorKind> {
        if s.is_catchable() {
            return Ok(s);
        }

        // This replicates cppnix's (mis?)handling of codepoints
        // above U+007f following 0x2d ('-')
        let s = s.to_str()?;
        let slice: &[u8] = s.as_ref();
        let (name, dash_and_version) = slice.split_at(
            slice
                .windows(2)
                .enumerate()
                .find_map(|x| match x {
                    (idx, [b'-', c1]) if !c1.is_ascii_alphabetic() => Some(idx),
                    _ => None,
                })
                .unwrap_or(slice.len()),
        );
        let version = dash_and_version
            .split_first()
            .map(|x| core::str::from_utf8(x.1))
            .unwrap_or(Ok(""))?;
        Ok(Value::attrs(NixAttrs::from_iter(
            [("name", core::str::from_utf8(name)?), ("version", version)].into_iter(),
        )))
    }

    #[builtin("partition")]
    async fn builtin_partition(co: GenCo, pred: Value, list: Value) -> Result<Value, ErrorKind> {
        let mut right: Vec<Value> = Default::default();
        let mut wrong: Vec<Value> = Default::default();

        let list: NixList = list.to_list()?;
        for elem in list {
            let result = generators::request_call_with(&co, pred.clone(), [elem.clone()]).await;

            if try_value!(generators::request_force(&co, result).await).as_bool()? {
                right.push(elem);
            } else {
                wrong.push(elem);
            };
        }

        let res = [
            ("right", Value::List(NixList::from(right))),
            ("wrong", Value::List(NixList::from(wrong))),
        ];

        Ok(Value::attrs(NixAttrs::from_iter(res.into_iter())))
    }

    #[builtin("removeAttrs")]
    async fn builtin_remove_attrs(
        co: GenCo,
        attrs: Value,
        keys: Value,
    ) -> Result<Value, ErrorKind> {
        let attrs = attrs.to_attrs()?;
        let keys = keys
            .to_list()?
            .into_iter()
            .map(|v| v.to_str())
            .collect::<Result<FxHashSet<_>, _>>()?;
        let res = attrs.iter().filter_map(|(k, v)| {
            if !keys.contains(k) {
                Some((k.clone(), v.clone()))
            } else {
                None
            }
        });
        Ok(Value::attrs(NixAttrs::from_iter(res)))
    }

    #[builtin("replaceStrings")]
    async fn builtin_replace_strings(
        co: GenCo,
        from: Value,
        to: Value,
        s: Value,
    ) -> Result<Value, ErrorKind> {
        let from = from.to_list()?;
        for val in &from {
            try_value!(generators::request_force(&co, val.clone()).await);
        }

        let to = to.to_list()?;
        for val in &to {
            try_value!(generators::request_force(&co, val.clone()).await);
        }

        let mut string = s.to_contextful_str()?;

        let mut res = BString::default();

        let mut i: usize = 0;
        let mut empty_string_replace = false;
        let mut context = NixContext::new();

        if let Some(string_context) = string.take_context() {
            context.extend(string_context.into_iter());
        }

        // This can't be implemented using Rust's string.replace() as
        // well as a map because we need to handle errors with results
        // as well as "reset" the iterator to zero for the replacement
        // everytime there's a successful match.
        // Also, Rust's string.replace allocates a new string
        // on every call which is not preferable.
        'outer: while i < string.len() {
            // Try a match in all the from strings
            for elem in std::iter::zip(from.iter(), to.iter()) {
                let from = elem.0.to_contextful_str()?;
                let mut to = elem.1.to_contextful_str()?;

                if i + from.len() > string.len() {
                    continue;
                }

                // We already applied a from->to with an empty from
                // transformation.
                // Let's skip it so that we don't loop infinitely
                if empty_string_replace && from.is_empty() {
                    continue;
                }

                // if we match the `from` string, let's replace
                if string[i..i + from.len()] == *from {
                    res.push_str(&to);
                    i += from.len();
                    if let Some(to_ctx) = to.take_context() {
                        context.extend(to_ctx.into_iter());
                    }

                    // remember if we applied the empty from->to
                    empty_string_replace = from.is_empty();

                    continue 'outer;
                }
            }

            // If we don't match any `from`, we simply add a character
            res.push_str(&string[i..i + 1]);
            i += 1;

            // Since we didn't apply anything transformation,
            // we reset the empty string replacement
            empty_string_replace = false;
        }

        // Special case when the string is empty or at the string's end
        // and one of the from is also empty
        for elem in std::iter::zip(from.iter(), to.iter()) {
            let from = elem.0.to_contextful_str()?;
            // We mutate `to` by consuming its context
            // if we perform a successful replacement.
            // Therefore, it's fine if `to` was mutate and we reuse it here.
            // We don't need to merge again the context, it's already in the right state.
            let mut to = elem.1.to_contextful_str()?;

            if from.is_empty() {
                res.push_str(&to);
                if let Some(to_ctx) = to.take_context() {
                    context.extend(to_ctx.into_iter());
                }
                break;
            }
        }

        Ok(Value::from(NixString::new_context_from(context, res)))
    }

    #[builtin("seq")]
    async fn builtin_seq(co: GenCo, _x: Value, y: Value) -> Result<Value, ErrorKind> {
        // The builtin calling infra has already forced both args for us, so
        // we just return the second and ignore the first
        Ok(y)
    }

    #[builtin("split")]
    async fn builtin_split(
        state: Rc<BuiltinState>,
        co: GenCo,
        regex: Value,
        str: Value,
    ) -> Result<Value, ErrorKind> {
        if str.is_catchable() {
            return Ok(str);
        }

        if regex.is_catchable() {
            return Ok(regex);
        }

        let s = str.to_contextful_str()?;
        let text = s.to_str()?;
        let re = regex.to_str()?;
        let re = re.to_str()?;
        let re = state
            .get_regex(re)
            .map_err(|_| ErrorKind::InvalidRegex(re.to_string()))?;
        let mut capture_locations = re.capture_locations();
        let num_captures = capture_locations.len();
        let mut ret = Vec::new();
        let mut pos = 0;

        while let Some(thematch) = re.captures_read_at(&mut capture_locations, text, pos) {
            // push the unmatched characters preceding the match
            ret.push(Value::from(NixString::new_inherit_context_from(
                &s,
                &text[pos..thematch.start()],
            )));

            // Push a list with one element for each capture
            // group in the regex, containing the characters
            // matched by that capture group, or null if no match.
            // We skip capture 0; it represents the whole match.
            let v: Vec<Value> = (1..num_captures)
                .map(|i| capture_locations.get(i))
                .map(|o| {
                    o.map(|(start, end)| {
                        // Here, a surprising thing happens: we silently discard the original
                        // context. This is as intended, Nix does the same.
                        Value::from(&text[start..end])
                    })
                    .unwrap_or(Value::Null)
                })
                .collect();
            ret.push(Value::List(NixList::from(v)));
            if pos == text.len() {
                break;
            }
            pos = thematch.end();
        }

        // push the unmatched characters following the last match
        // Here, a surprising thing happens: we silently discard the original
        // context. This is as intended, Nix does the same.
        ret.push(Value::from(&text[pos..]));

        Ok(Value::List(NixList::from(ret)))
    }

    #[builtin("sort")]
    async fn builtin_sort(co: GenCo, comparator: Value, list: Value) -> Result<Value, ErrorKind> {
        let list = list.to_list()?;
        let mut len = list.len();
        let mut data = list.into_inner();

        // Asynchronous sorting algorithm in which the comparator can make use of
        // VM requests (required as `builtins.sort` uses comparators written in
        // Nix).
        //
        // This is a simple, optimised bubble sort implementation. The choice of
        // algorithm is constrained by the comparator in Nix not being able to
        // yield equality, and us being unable to use the standard library
        // implementation of sorting (which is a lot longer, but a lot more
        // efficient) here.
        // TODO(amjoseph): Investigate potential impl in Nix code, or Snix bytecode.
        loop {
            let mut new_len = 0;
            for i in 1..len {
                if try_value!(
                    generators::request_force(
                        &co,
                        generators::request_call_with(
                            &co,
                            comparator.clone(),
                            [data[i].clone(), data[i - 1].clone()],
                        )
                        .await,
                    )
                    .await
                )
                .as_bool()
                .context("evaluating comparator in `builtins.sort`")?
                {
                    data.swap(i, i - 1);
                    new_len = i;
                }
            }

            if new_len == 0 {
                break;
            }

            len = new_len;
        }

        Ok(Value::List(data.into()))
    }

    #[builtin("splitVersion")]
    async fn builtin_split_version(co: GenCo, s: Value) -> Result<Value, ErrorKind> {
        if s.is_catchable() {
            return Ok(s);
        }
        let s = s.to_str()?;
        let s = VersionPartsIter::new((&s).into());

        let parts = s
            .map(|s| {
                Value::from(match s {
                    VersionPart::Number(n) => n,
                    VersionPart::Word(w) => w,
                })
            })
            .collect::<Vec<Value>>();
        Ok(Value::List(NixList::construct(parts.len(), parts)))
    }

    #[builtin("stringLength")]
    async fn builtin_string_length(co: GenCo, #[lazy] s: Value) -> Result<Value, ErrorKind> {
        // also forces the value
        let span = generators::request_span(&co).await;
        let s = s
            .coerce_to_string(
                co,
                CoercionKind {
                    strong: false,
                    import_paths: true,
                },
                span,
            )
            .await?;

        if s.is_catchable() {
            return Ok(s);
        }

        Ok(Value::Integer(s.to_contextful_str()?.len() as i64))
    }

    #[builtin("sub")]
    async fn builtin_sub(co: GenCo, x: Value, y: Value) -> Result<Value, ErrorKind> {
        arithmetic_op!(&x, &y, -)
    }

    #[builtin("substring")]
    async fn builtin_substring(
        co: GenCo,
        start: Value,
        len: Value,
        s: Value,
    ) -> Result<Value, ErrorKind> {
        let beg = start.as_int()?;
        let len = len.as_int()?;
        let span = generators::request_span(&co).await;
        let x = s
            .coerce_to_string(
                co,
                CoercionKind {
                    strong: false,
                    import_paths: true,
                },
                span,
            )
            .await?;
        if x.is_catchable() {
            return Ok(x);
        }
        let x = x.to_contextful_str()?;

        if beg < 0 {
            return Err(ErrorKind::IndexOutOfBounds { index: beg });
        }
        let beg = beg as usize;

        // Nix doesn't assert that the length argument is
        // non-negative when the starting index is GTE the
        // string's length.
        if beg >= x.len() {
            return Ok(Value::from(NixString::new_inherit_context_from(
                &x,
                BString::default(),
            )));
        }

        let end = if len < 0 {
            x.len()
        } else {
            cmp::min(beg + (len as usize), x.len())
        };

        Ok(Value::from(NixString::new_inherit_context_from(
            &x,
            &x[beg..end],
        )))
    }

    #[builtin("tail")]
    async fn builtin_tail(co: GenCo, list: Value) -> Result<Value, ErrorKind> {
        if list.is_catchable() {
            return Ok(list);
        }

        let xs = list.to_list()?;

        if xs.is_empty() {
            Err(ErrorKind::TailEmptyList)
        } else {
            let output = xs.into_iter().skip(1).collect::<Vec<_>>();
            Ok(Value::List(NixList::construct(output.len(), output)))
        }
    }

    #[builtin("throw")]
    async fn builtin_throw(co: GenCo, message: Value) -> Result<Value, ErrorKind> {
        // If it's already some error, let's propagate it immediately.
        if message.is_catchable() {
            return Ok(message);
        }

        // TODO(sterni): coerce to string
        // We do not care about the context here explicitly.
        Ok(Value::from(CatchableErrorKind::Throw(message.to_str()?)))
    }

    #[builtin("toString")]
    async fn builtin_to_string(co: GenCo, #[lazy] x: Value) -> Result<Value, ErrorKind> {
        // TODO(edef): please fix me w.r.t. to catchability.
        // coerce_to_string forces for us
        // FIXME: should `coerce_to_string` preserve context?
        // it does for now.
        let span = generators::request_span(&co).await;
        x.coerce_to_string(
            co,
            CoercionKind {
                strong: true,
                import_paths: false,
            },
            span,
        )
        .await
    }

    #[builtin("toXML")]
    async fn builtin_to_xml(co: GenCo, value: Value) -> Result<Value, ErrorKind> {
        let value = generators::request_deep_force(&co, value).await;
        if value.is_catchable() {
            return Ok(value);
        }

        let mut buf: Vec<u8> = vec![];
        let context = to_xml::value_to_xml(&mut buf, &value)?;

        Ok(NixString::new_context_from(context, buf).into())
    }

    #[builtin("trace")]
    async fn builtin_trace(co: GenCo, message: Value, value: Value) -> Result<Value, ErrorKind> {
        // TODO(grfn): `trace` should be pluggable and capturable, probably via a method on
        // the VM
        eprintln!("trace: {} :: {}", message, message.type_of());
        Ok(value)
    }

    #[builtin("toPath")]
    async fn builtin_to_path(co: GenCo, s: Value) -> Result<Value, ErrorKind> {
        if s.is_catchable() {
            return Ok(s);
        }

        let path = try_cek_to_value!(coerce_value_to_path(&co, s).await?);
        let path: Value = crate::value::canon_path(path).into();
        let span = generators::request_span(&co).await;
        path.coerce_to_string(
            co,
            CoercionKind {
                strong: false,
                import_paths: false,
            },
            span,
        )
        .await
    }

    #[builtin("tryEval")]
    async fn builtin_try_eval(co: GenCo, #[lazy] e: Value) -> Result<Value, ErrorKind> {
        let res = match generators::request_try_force(&co, e).await {
            Value::Catchable(_) => [("value", false.into()), ("success", false.into())],
            value => [("value", value), ("success", true.into())],
        };

        Ok(Value::attrs(NixAttrs::from_iter(res.into_iter())))
    }

    #[builtin("typeOf")]
    async fn builtin_type_of(co: GenCo, x: Value) -> Result<Value, ErrorKind> {
        if x.is_catchable() {
            return Ok(x);
        }

        Ok(Value::from(x.type_of()))
    }

    #[builtin("zipAttrsWith")]
    async fn builtin_zip_attrs_with(
        co: GenCo,
        #[lazy] f: Value,
        list: Value,
    ) -> Result<Value, ErrorKind> {
        let mut merged: FxHashMap<NixString, Vec<Value>> = FxHashMap::default();

        // For each key, merge values of the same key into one single attrset
        for set in list.to_list()? {
            let set = generators::request_force(&co, set).await;
            let set = set.to_attrs()?;
            for (key, val) in *set {
                match merged.entry(key) {
                    Entry::Occupied(mut occupied) => occupied.get_mut().push(val),
                    Entry::Vacant(vacant) => {
                        vacant.insert(vec![val]);
                    }
                }
            }
        }

        let span = generators::request_span(&co).await;

        // apply the function to each element
        let attrs = merged.into_iter().map(|(key, vals)| {
            let val = Value::Thunk(Thunk::new_suspended_call(
                Value::Thunk(Thunk::new_suspended_call(
                    f.clone(),
                    key.clone().into(),
                    span,
                )),
                Value::List(NixList::construct(vals.len(), vals)),
                span,
            ));
            (key, val)
        });

        Ok(Value::attrs(NixAttrs::from_iter(attrs)))
    }
}

/// Internal helper function for genericClosure, determining whether a
/// value has been seen before.
async fn bgc_insert_key(
    co: &GenCo,
    key: Value,
    done: &mut Vec<Value>,
) -> Result<Result<bool, CatchableErrorKind>, ErrorKind> {
    for existing in done.iter() {
        if try_cek!(
            generators::check_equality(
                co,
                existing.clone(),
                key.clone(),
                // TODO(tazjin): not actually sure which semantics apply here
                PointerEquality::ForbidAll,
            )
            .await?
        ) {
            return Ok(Ok(false));
        }
    }

    done.push(key);
    Ok(Ok(true))
}

/// The set of standard pure builtins in Nix, mostly concerned with
/// data structure manipulation (string, attrs, list, etc. functions).
pub fn pure_builtins() -> Vec<(&'static str, Value)> {
    let mut result = pure_builtins::builtins(Rc::new(BuiltinState::default()));

    // Pure-value builtins
    result.push(("nixVersion", Value::from("2.18.3-compat-snix-0.1")));
    result.push(("langVersion", Value::Integer(6)));
    result.push(("null", Value::Null));
    result.push(("true", Value::Bool(true)));
    result.push(("false", Value::Bool(false)));

    result.push((
        "currentSystem",
        crate::systems::llvm_triple_to_nix_double(CURRENT_PLATFORM).into(),
    ));

    result.push((
        "__curPos",
        Value::Thunk(Thunk::new_suspended_native(Box::new(move || {
            // TODO: implement for nixpkgs compatibility
            Ok(Value::attrs(NixAttrs::from_iter([
                ("line", 42.into()),
                ("column", 42.into()),
                ("file", Value::String("/deep/thought".into())),
            ])))
        }))),
    ));

    result
}

#[builtins]
mod placeholder_builtins {
    use crate::NixContext;

    use super::*;

    #[builtin("unsafeDiscardStringContext")]
    async fn builtin_unsafe_discard_string_context(
        co: GenCo,
        s: Value,
    ) -> Result<Value, ErrorKind> {
        let span = generators::request_span(&co).await;
        let mut v = s
            .coerce_to_string(
                co,
                // It's weak because
                // lists, integers, floats and null are not
                // accepted as parameters.
                CoercionKind {
                    strong: false,
                    import_paths: true,
                },
                span,
            )
            .await?
            .to_contextful_str()?;
        v.clear_context();
        Ok(Value::from(v))
    }

    #[builtin("unsafeDiscardOutputDependency")]
    async fn builtin_unsafe_discard_output_dependency(
        co: GenCo,
        s: Value,
    ) -> Result<Value, ErrorKind> {
        let span = generators::request_span(&co).await;
        let mut v = s
            .coerce_to_string(
                co,
                // It's weak because
                // lists, integers, floats and null are not
                // accepted as parameters.
                CoercionKind {
                    strong: false,
                    import_paths: true,
                },
                span,
            )
            .await?
            .to_contextful_str()?;

        // If there's any context, we will swap any ... by a path one.
        if let Some(c) = v.take_context() {
            let mut context = NixContext::new();
            context.extend(c.into_iter().map(|elem| match elem {
                crate::NixContextElement::Derivation(drv_path) => {
                    crate::NixContextElement::Plain(drv_path.to_string())
                }
                elem => elem.clone(),
            }));

            return Ok(Value::String(NixString::new_context_from(context, v)));
        }
        Ok(Value::from(v))
    }

    #[builtin("addErrorContext")]
    async fn builtin_add_error_context(
        co: GenCo,
        #[lazy] _context: Value,
        #[lazy] val: Value,
    ) -> Result<Value, ErrorKind> {
        generators::emit_warning_kind(&co, WarningKind::NotImplemented("builtins.addErrorContext"))
            .await;
        Ok(val)
    }

    #[builtin("unsafeGetAttrPos")]
    async fn builtin_unsafe_get_attr_pos(
        co: GenCo,
        _name: Value,
        _attrset: Value,
    ) -> Result<Value, ErrorKind> {
        // TODO: implement for nixpkgs compatibility
        generators::emit_warning_kind(
            &co,
            WarningKind::NotImplemented("builtins.unsafeGetAttrsPos"),
        )
        .await;
        let res = [
            ("line", 42.into()),
            ("column", 42.into()),
            ("file", Value::String("/deep/thought".into())),
        ];
        Ok(Value::attrs(NixAttrs::from_iter(res.into_iter())))
    }
}

pub fn placeholders() -> Vec<(&'static str, Value)> {
    placeholder_builtins::builtins()
}
