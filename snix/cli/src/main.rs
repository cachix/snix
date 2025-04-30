use clap::Parser;
use mimalloc::MiMalloc;
use snix_cli::args::Args;
use snix_cli::repl::Repl;
use snix_cli::{AllowIncomplete, init_io_handle, interpret};
use snix_eval::EvalMode;
use snix_eval::observer::DisassemblingObserver;
use snix_glue::snix_store_io::SnixStoreIO;
use std::io::Write;
use std::rc::Rc;
use std::{fs, path::PathBuf};

#[global_allocator]
static GLOBAL: MiMalloc = MiMalloc;

/// Interpret the given code snippet, but only run the Svix compiler
/// on it and return errors and warnings.
fn lint<E: Write + Clone + Send>(
    stderr: &mut E,
    code: &str,
    path: Option<PathBuf>,
    args: &Args,
) -> bool {
    let mut eval_builder = snix_eval::Evaluation::builder_impure();

    if args.strict {
        eval_builder = eval_builder.mode(EvalMode::Strict);
    }

    let source_map = eval_builder.source_map().clone();

    let mut compiler_observer = DisassemblingObserver::new(source_map.clone(), stderr.clone());

    if args.dump_bytecode {
        eval_builder.set_compiler_observer(Some(&mut compiler_observer));
    }

    if args.trace_runtime {
        writeln!(
            stderr,
            "warning: --trace-runtime has no effect with --compile-only"
        )
        .unwrap();
    }

    let eval = eval_builder.build();
    let result = eval.compile_only(code, path);

    if args.display_ast {
        if let Some(ref expr) = result.expr {
            writeln!(stderr, "AST: {}", snix_eval::pretty_print_expr(expr)).unwrap();
        }
    }

    for error in &result.errors {
        error.fancy_format_write(stderr);
    }

    for warning in &result.warnings {
        warning.fancy_format_write(stderr, &source_map);
    }

    // inform the caller about any errors
    result.errors.is_empty()
}

fn main() {
    let args = Args::parse();

    let tracing_handle = snix_tracing::TracingBuilder::default()
        .enable_progressbar()
        .build()
        .expect("unable to set up tracing subscriber");
    let mut stdout = tracing_handle.get_stdout_writer();
    let mut stderr = tracing_handle.get_stderr_writer();

    let tokio_runtime = tokio::runtime::Runtime::new().expect("failed to setup tokio runtime");

    let io_handle = init_io_handle(&tokio_runtime, &args);

    if let Some(file) = &args.script {
        run_file(&mut stdout, &mut stderr, io_handle, file.clone(), &args)
    } else if let Some(expr) = &args.expr {
        if !interpret(
            &mut stderr,
            io_handle,
            expr,
            None,
            &args,
            false,
            AllowIncomplete::RequireComplete,
            None, // TODO(aspen): Pass in --arg/--argstr here
            None,
            None,
        )
        .unwrap()
        .finalize(&mut stdout)
        {
            std::process::exit(1);
        }
    } else {
        let mut repl = Repl::new(io_handle, &args);
        repl.run(&mut stdout, &mut stderr)
    }
}

fn run_file<O: Write, E: Write + Clone + Send>(
    stdout: &mut O,
    stderr: &mut E,
    io_handle: Rc<SnixStoreIO>,
    mut path: PathBuf,
    args: &Args,
) {
    if path.is_dir() {
        path.push("default.nix");
    }
    let contents = fs::read_to_string(&path).expect("failed to read the input file");

    let success = if args.compile_only {
        lint(stderr, &contents, Some(path), args)
    } else {
        interpret(
            stderr,
            io_handle,
            &contents,
            Some(path),
            args,
            false,
            AllowIncomplete::RequireComplete,
            None,
            None,
            None,
        )
        .unwrap()
        .finalize(stdout)
    };

    if !success {
        std::process::exit(1);
    }
}
