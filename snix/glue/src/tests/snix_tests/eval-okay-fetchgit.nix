let
assertTimestamps = result:
  let
    requiredAttrs = ["lastModified" "lastModifiedDate"];
    hasAttr = attr:
      if builtins.hasAttr attr result
      then true
      else throw "Required attribute '${attr}' is missing in result";
    _ = map hasAttr requiredAttrs;
  in
    builtins.removeAttrs result requiredAttrs;
    in [
      # fetchurl with url and sha256
      (assertTimestamps (builtins.fetchGit {
        url = "https://git.snix.dev/snix/snix.git";
        ref = "canon";
        rev = "75d788b0f24e8de033a22c0869032549d602d4f6";
      }))
      (assertTimestamps (builtins.fetchGit {
        url = "https://github.com/XAMPPRocky/octocrab";
        rev = "ce8c885dc2701c891ce868c846fa25d32fd44ba2";
      }))
      # TODO: fetchGit without rev is not fully supported.
      #(assertTimestamps (builtins.fetchGit {
      #  url = "https://github.com/NixOS/nix";
      #  ref = "refs/tags/0.1";
      #}))
    ]
