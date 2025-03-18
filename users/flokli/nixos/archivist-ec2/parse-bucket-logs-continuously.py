import boto3
import datetime
import os
import re
import subprocess
import tempfile

s3 = boto3.resource('s3')
bucket_name = "nix-archeologist"
prefix = "nix-cache-bucket-logs/"

bucket = s3.Bucket(bucket_name)

key_pattern = re.compile(r'.*\/(?P<y>\d{4})-(?P<m>\d{2})-(?P<d>\d{2})\.parquet$')  # noqa: E501

# get a listing (which is sorted), grab the most recent key
last_elem = list(
    o for o in bucket.objects.filter(Prefix=prefix)
    if key_pattern.match(o.key)
).pop()

# extract the date of that key.
m = key_pattern.search(last_elem.key)
last_elem_date = datetime.date(int(m.group("y")), int(m.group("m")), int(m.group("d")))  # noqa: E501

# get the current date (UTC)
now = datetime.datetime.now(tz=datetime.UTC)
now_date = datetime.date(now.year, now.month, now.day)

while True:
    # Calculate what date would be processed next.
    next_elem_date = last_elem_date + datetime.timedelta(days=1)

    # If that's today, we don't want to process it.
    if next_elem_date == now_date:
        print("Caught up, would process data from today.")
        break

    # If we'd be processing data from yesterday, but it's right after midnight,
    # also don't process - data might still be flushed.
    if (next_elem_date + datetime.timedelta(days=1) == now_date) and now.hour == 0:  # noqa: E501
        print("Not processing data from previous day right after midnight")
        break

    src = f"http://nix-cache-log.s3.amazonaws.com/log/{next_elem_date.isoformat()}-*"  # noqa: E501

    # Invoke parse-bucket-logs script inside a tempdir and upload on success.
    with tempfile.TemporaryDirectory() as td:
        work_file_name = os.path.join(td, "output.parquet")
        args = ["archivist-parse-bucket-logs", src, work_file_name]
        subprocess.run(
            args,
            check=True  # throw exception if nonzero exit code
        )

        dest_key = f"{prefix}{next_elem_date.isoformat()}.parquet"

        # Upload the file
        print(f"uploading to s3://{bucket_name}{dest_key}")
        bucket.upload_file(work_file_name, dest_key)

    last_elem_date = next_elem_date
