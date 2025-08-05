use crate::derivation::{Derivation, DerivationError};
use crate::store_path;

/// Validates an output name using derivation output name rules.
///
/// Output names must:
/// - Not be empty
/// - Not be "drv" (reserved name that would conflict with the existing drvPath key in builtins.derivation)
/// - Pass the `store_path::validate_name` check
///
/// This function is used by both derivation validation and builtins.placeholder.
pub fn validate_output_name(output_name: &str) -> Result<(), DerivationError> {
    if output_name.is_empty()
        || output_name == "drv"
        || store_path::validate_name(output_name.as_bytes()).is_err()
    {
        return Err(DerivationError::InvalidOutputName(output_name.to_string()));
    }
    Ok(())
}

impl Derivation {
    /// validate ensures a Derivation struct is properly populated,
    /// and returns a [DerivationError] if not.
    ///
    /// if `validate_output_paths` is set to false, the output paths are
    /// excluded from validation.
    ///
    /// This is helpful to validate struct population before invoking
    /// [Derivation::calculate_output_paths].
    pub fn validate(&self, validate_output_paths: bool) -> Result<(), DerivationError> {
        // Ensure the number of outputs is > 1
        if self.outputs.is_empty() {
            return Err(DerivationError::NoOutputs());
        }

        // Validate all outputs
        for (output_name, output) in &self.outputs {
            validate_output_name(output_name)?;

            if output.is_fixed() {
                if self.outputs.len() != 1 {
                    return Err(DerivationError::MoreThanOneOutputButFixed());
                }
                if output_name != "out" {
                    return Err(DerivationError::InvalidOutputNameForFixed(
                        output_name.to_string(),
                    ));
                }
            }

            if let Err(e) = output.validate(validate_output_paths) {
                return Err(DerivationError::InvalidOutput(output_name.to_string(), e));
            }
        }

        // Validate all input_derivations
        for (input_derivation_path, output_names) in &self.input_derivations {
            // Validate input_derivation_path
            if !input_derivation_path.name().ends_with(".drv") {
                return Err(DerivationError::InvalidInputDerivationPrefix(
                    input_derivation_path.to_string(),
                ));
            }

            if output_names.is_empty() {
                return Err(DerivationError::EmptyInputDerivationOutputNames(
                    input_derivation_path.to_string(),
                ));
            }

            for output_name in output_names.iter() {
                // For input derivation output names, we use the same validation
                // but map the error to the appropriate InputDerivationOutputName variant
                if let Err(DerivationError::InvalidOutputName(_)) =
                    validate_output_name(output_name)
                {
                    return Err(DerivationError::InvalidInputDerivationOutputName(
                        input_derivation_path.to_string(),
                        output_name.to_string(),
                    ));
                }
            }
        }

        // validate platform
        if self.system.is_empty() {
            return Err(DerivationError::InvalidPlatform(self.system.to_string()));
        }

        // validate builder
        if self.builder.is_empty() {
            return Err(DerivationError::InvalidBuilder(self.builder.to_string()));
        }

        // validate env, none of the keys may be empty.
        // We skip the `name` validation seen in go-nix.
        for k in self.environment.keys() {
            if k.is_empty() {
                return Err(DerivationError::InvalidEnvironmentKey(k.to_string()));
            }
        }

        Ok(())
    }
}

#[cfg(test)]
mod test {
    use std::collections::BTreeMap;

    use super::validate_output_name;
    use crate::derivation::{CAHash, Derivation, DerivationError, Output};

    /// Test the validate_output_name function with valid names
    #[test]
    fn test_validate_output_name_valid() {
        // Valid output names should pass
        assert!(validate_output_name("out").is_ok());
        assert!(validate_output_name("dev").is_ok());
        assert!(validate_output_name("lib").is_ok());
        assert!(validate_output_name("bin").is_ok());
        assert!(validate_output_name("debug").is_ok());
    }

    /// Test the validate_output_name function with invalid names
    #[test]
    fn test_validate_output_name_invalid() {
        // Empty name should fail
        assert!(matches!(
            validate_output_name(""),
            Err(DerivationError::InvalidOutputName(_))
        ));

        // "drv" is reserved and should fail
        assert!(matches!(
            validate_output_name("drv"),
            Err(DerivationError::InvalidOutputName(_))
        ));

        // Invalid characters should fail
        assert!(matches!(
            validate_output_name("invalid/name"),
            Err(DerivationError::InvalidOutputName(_))
        ));

        assert!(matches!(
            validate_output_name("invalid name"),
            Err(DerivationError::InvalidOutputName(_))
        ));
    }

    /// Regression test: produce a Derivation that's almost valid, except its
    /// fixed-output output has the wrong hash specified.
    #[test]
    fn output_validate() {
        let mut outputs = BTreeMap::new();
        outputs.insert(
            "out".to_string(),
            Output {
                path: None,
                ca_hash: Some(CAHash::Text([0; 32])), // This is disallowed
            },
        );

        let drv = Derivation {
            arguments: vec![],
            builder: "/bin/sh".to_string(),
            outputs,
            system: "x86_64-linux".to_string(),
            ..Default::default()
        };

        drv.validate(false).expect_err("must fail");
    }
}
