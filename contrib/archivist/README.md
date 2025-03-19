# archivist

This directory contains various scripts and helpers used for nix-archivist tasks.

It's used from the archivist EC2 instance, as well as standalone.

## AWS Profile setup
There's 2 AWS Accounts, reachable via the nixos.awsapps.com SSO portal.

### archeologist
This is assuming the `archeologist` AWS role in the main NixOS account.

### archivist
This is a separate AWS Account, only for the archivist project. We can assume
`AWSAdministratorAccess` in there.

## archivist-ec2 Machine
The `archivist-ec2` machine currently is deployed in the main NixOS account.

It regularly processes S3 bucket logs and dumps them in parquet format into
another bucket.
In the future, we want to move this machine to the dedicated `archivist` AWS
account.
