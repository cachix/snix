[
  # Test Git URL format
  (builtins.parseFlakeRef "git+https://github.com/example/repo.git")

  # Test GitHub URL format
  (builtins.parseFlakeRef "github:user/project")

  # Test GitHub URL with ref
  (builtins.parseFlakeRef "github:user/project/branch")

  # Test extraneous query params
  (builtins.parseFlakeRef "github:user/project/branch?foo=1")

  # Test GitLab URL format
  (builtins.parseFlakeRef "gitlab:user/project")

  # Test path URL format
  (builtins.parseFlakeRef "path:/path/to/project")
]
