let
  # Remove timing-dependent fields to make assertions stable
  assertTimestamps = result:
    builtins.removeAttrs result ["lastModified" "lastModifiedDate"];

  # Function to parse a flake reference URI and compare with fetchTree result
  assertFlakeRef = uri:
    let
      parsedRef = builtins.parseFlakeRef uri;
      uriResult = builtins.fetchTree uri;
      attrsResult = builtins.fetchTree parsedRef;
    in
    # Return both the parsed reference and the fetch result for comparison
    {
      inherit uri;
      parsedRef = parsedRef;
      uriResult = assertTimestamps uriResult;
      attrsResult = assertTimestamps attrsResult;
    };
in [
  # Git URL format
  (assertFlakeRef "git+https://github.com/octocat/Hello-World.git")
  (assertFlakeRef "git+https://github.com/octocat/Hello-World.git?ref=octocat-patch-1&rev=b1b3f9723831141a31a1a7252a213e216ea76e56&shallow=1&submodules=1&allRefs=1")
  (assertFlakeRef "git+ssh://git@github.com/octocat/Hello-World.git")
  (assertFlakeRef "git+https://github.com/octocat/Hello-World.git")
  (assertFlakeRef "git+http://github.com/octocat/Hello-World.git")

  # Git attribute set format
  (assertTimestamps (builtins.fetchTree {
    type = "git";
    url = "https://github.com/octocat/Hello-World.git";
  }))
  (assertTimestamps (builtins.fetchTree {
    type = "git";
    url = "https://github.com/octocat/Hello-World.git";
    ref = "octocat-patch-1";
    rev = "b1b3f9723831141a31a1a7252a213e216ea76e56";
    shallow = true;
    submodules = true;
    allRefs = true;
  }))

  # GitHub URL format
  (assertFlakeRef "github:octocat/Hello-World/master")
  (assertFlakeRef "github:octocat/Hello-World/b1b3f9723831141a31a1a7252a213e216ea76e56")

  # GitHub attribute set format
  (assertTimestamps (builtins.fetchTree {
    type = "github";
    owner = "octocat";
    repo = "Hello-World";
  }))
  (assertTimestamps (builtins.fetchTree {
    type = "github";
    owner = "octocat";
    repo = "Hello-World";
    ref = "master";
  }))
  (assertTimestamps (builtins.fetchTree {
    type = "github";
    owner = "octocat";
    repo = "Hello-World";
    rev = "b1b3f9723831141a31a1a7252a213e216ea76e56";
  }))

  # GitLab URL format
  (assertFlakeRef "gitlab:k0001/moto")

  # Self-Hosted GitLab URL format
  (assertFlakeRef "gitlab:ghc/ci-config/master?host=gitlab.haskell.org")

  # GitLab attribute set format
  (assertTimestamps (builtins.fetchTree {
    type = "gitlab";
    owner = "k0001";
    repo = "moto";
  }))
  (assertTimestamps (builtins.fetchTree {
    type = "gitlab";
    owner = "ghc";
    repo = "ci-config";
    ref = "master";
    host = "gitlab.haskell.org";
  }))

  # SourceHut URL format
  (assertFlakeRef "sourcehut:~kennylevinsen/wldash")

  # SourceHut attribute set format
  (assertTimestamps (builtins.fetchTree {
    type = "sourcehut";
    owner = "~kennylevinsen";
    repo = "wldash";
  }))

  # TODO: No Mercurial support: https://github.com/search?q=path%3A%2F%5Eflake.lock%24%2F+%28%2F%22hg%22%2F+OR+%2F%22mercurial%22%2F%29&type=code

  # File/Tarball URL format
  (assertFlakeRef "http://ftp.gnu.org/gnu/hello/hello-2.12.tar.gz")
  (assertFlakeRef "https://ftp.gnu.org/gnu/hello/hello-2.12.tar.gz")

  # File attribute set format
  (assertTimestamps (builtins.fetchTree {
    type = "file";
    url = "https://ftp.gnu.org/gnu/hello/hello-2.12.tar.gz";
  }))

  # Tarball attribute set format
  (assertTimestamps (builtins.fetchTree {
    type = "tarball";
    url = "https://ftp.gnu.org/gnu/hello/hello-2.12.tar.gz";
  }))
]
