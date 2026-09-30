# A settings file from before several repositories: one `repo`, no
# `repos`. It must keep loading, and mean exactly what it meant.
%{
  rotate_seconds: 20,
  brand: %{name: "Acme"},
  github: %{
    repo: "acme/shop",
    branch: "trunk",
    poll_seconds: 45,
    gate_workflow: "gate.yml",
    gate_check: "gate",
    dev_deploy: "dev-deploy.yml",
    prod_deploy: "prod-deploy.yml",
    deploy_workflows: ["dev-deploy.yml", "prod-deploy.yml"],
    lanes: [
      %{label: "Gate", workflows: ["gate.yml"]},
      %{label: "Prod", workflows: ["prod-deploy.yml"]}
    ]
  }
}
