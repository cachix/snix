use std::env;
use std::process::Command;
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 {
        eprintln!("needs two args, input s3 url (glob) and output pq file");
        return ExitCode::FAILURE;
    }

    let input_files = &args[1];
    let output_file = &args[2];

    let mut cmd = Command::new("clickhouse-local");
    cmd.arg("--progress")
        .arg("-q")
        .arg(format!(r#"SELECT
        key,
        toInt64(nullif(http_status, '-')) AS http_status,
        toInt64(nullif(object_size_str, '-')) AS object_size,
        toInt64(nullif(bytes_sent_str, '-')) AS bytes_sent,
        nullif(user_agent, '-') AS user_agent,
        operation,
        nullif(requester, '-') AS requester,
        parseDateTime(timestamp_str, '%d/%b/%Y:%k:%i:%s %z') AS timestamp
    FROM s3(
        '{}',
        'Regexp',
        'owner String , bucket String, timestamp_str String, remote_ip String, requester LowCardinality(String), request_id String, operation LowCardinality(String), key String, request_uri String, http_status String, error_code String, bytes_sent_str String, object_size_str String, total_time String, turn_around_time String, referer String, user_agent String, version_id String, host_id String, signature_version String, cipher_suite String, authentication_type String, host_header String, tls_version String, access_point_arn String, acl_required String'
    )
    ORDER BY timestamp ASC
    SETTINGS
        format_regexp_skip_unmatched = 1,
        format_regexp = '(\\S+) (\\S+) \\[(.*)\\] (\\S+) (\\S+) (\\S+) (\\S+) (\\S+) ((?:\\S+ \\S+ \\S+)|\\S+) (\\S+) (\\S+) (\\S+) (\\S+) (\\S+) (\\S+) (\\S+) ("\\S+") (\\S+) (\\S+) (\\S+) (\\S+) (\\S+) (\\S+) (\\S+) (\\S+) (\\S+).*',
        output_format_parquet_compression_method = 'zstd'
    INTO OUTFILE '{}' FORMAT Parquet"#, input_files, output_file));

    cmd.status().expect("clickhouse-local failed");

    ExitCode::SUCCESS
}
