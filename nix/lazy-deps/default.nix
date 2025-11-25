# Helper function to synthesize a directory of "lazy-built" binaries
# that can be added to $PATH inside of a repository.
#
# Using this, a Nix shell environment in some repository can contain
# several slow-to-build commands without blowing up evaluation and
# build time whenever the shell is loaded.
#
# Note that the generated script is deliberately impure to speed up
# evaluation, and expects both `git` and `nix-build` to exist in the
# user's $PATH. If required, this can be done in the shell
# configuration invoking this function.
{ pkgs, lib, ... }:

let
  inherit (builtins) attrNames attrValues mapAttrs;
  inherit (lib) fix concatStringsSep;

  # Create the case statement for a command invocations, optionally
  # overriding the `TARGET_TOOL` variable.
  invoke =
    name:
    {
      attr,
      cmd ? null,
    }:
    ''
      ${name})
        attr="${attr}"
        ${if cmd != null then "TARGET_TOOL=\"${cmd}\"\n;;" else ";;"}
    '';

  # Create command to symlink to the dispatch script for each tool.
  link = name: "ln -s $target $out/bin/${name}";

  invocations = tools: concatStringsSep "\n" (attrValues (mapAttrs invoke tools));
in
fix (
  self:

  # Attribute set of tools that should be lazily-added to the $PATH.
  #
  # The name of each attribute is used as the command name (on $PATH).
  # It must contain the keys 'attr' (containing the Nix attribute path
  # to the tool's derivation from the top-level), and may optionally
  # contain the key 'cmd' to override the name of the binary inside the
  # derivation.
  tools:

  pkgs.runCommand "lazy-dispatch"
    {
      passthru.overrideDeps = newTools: self (tools // newTools);
      passthru.tools = tools;

      text = ''
        #!${pkgs.runtimeShell}
        set -ue

        if ! type git>/dev/null || ! type nix-build>/dev/null; then
          echo "The 'git' and 'nix-build' commands must be available." >&2
          exit 127
        fi

        readonly REPO_ROOT=$(git rev-parse --show-toplevel)
        TARGET_TOOL=$(basename "$0")

        case "''${TARGET_TOOL}" in
        ${invocations tools}
        *)
          echo "''${TARGET_TOOL} is currently not installed in this repository." >&2
          exit 127
          ;;
        esac

        result=$(nix-build --no-out-link --attr "''${attr}" "''${REPO_ROOT}")
        PATH="''${result}/bin:$PATH"
        exec "''${TARGET_TOOL}" "''${@}"
      '';

      # Access this to get a compatible nix-shell
      passthru.devShell = pkgs.mkShellNoCC {
        name = "${self.name}-shell";
        packages = [ self ];
      };
    }
    ''
      # Write the dispatch code
      target=$out/bin/__dispatch
      mkdir -p "$(dirname "$target")"
      echo "$text" > $target
      chmod +x $target

      # Add symlinks from all the tools to the dispatch
      ${concatStringsSep "\n" (map link (attrNames tools))}

      # Check that it's working-ish
      ${pkgs.stdenv.shellDryRun} $target
    ''
)
