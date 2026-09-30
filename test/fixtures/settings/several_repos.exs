# Several repositories: the shared GitHub settings, then a list where an
# entry is a name, or a map that changes some settings for that repository.
%{
  github: %{
    branch: "main",
    gate_workflow: "ci.yml",
    repos: [
      "acme/api",
      %{
        repo: "acme/mobile",
        gate_workflow: "build.yml",
        lanes: [%{label: "Build", workflows: ["build.yml"]}]
      },
      "acme/web"
    ]
  }
}
