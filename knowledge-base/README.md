# EKS Knowledge Base

The `DEPLOYMENT-RUNBOOK.md` and `LIMITATIONS.md` files in this folder describe the environment for the currently checked-out Git branch. This branch contains development guidance. The staging branch should contain staging-specific versions at these same paths. Git shows the content belonging to the branch you check out; do not copy development-only instructions into staging unchanged.

- [Deployment runbook for the current branch](DEPLOYMENT-RUNBOOK.md)
- [Limitations for the current branch](LIMITATIONS.md)
- [Shared Terraform codebase guide](CODEBASE-GUIDE.md)
- [General EKS learning notes](EKS-LEARNING-NOTES.md)

The environment selector reads the Git branch, validates the matching local variable file, and selects that environment's backend state. You are currently on `dev`; confirm the target before planning or deploying:

```sh
bash scripts/terraform-env.sh show
bash scripts/terraform-env.sh plan
# Review the complete plan and confirm the account, resources, and state key.
bash scripts/terraform-env.sh apply
# After apply, write this branch's Terraform outputs to knowledge-base/output.md.
bash scripts/terraform-env.sh output
```

`apply` provisions billable AWS resources and asks for confirmation. Run it only after reviewing the plan and confirming that the checked-out branch is the environment you intend to deploy. The same command on the `staging` branch selects staging's state and variable file.

The `output` action overwrites `knowledge-base/output.md` with outputs from the currently selected branch's Terraform state. The file is branch-specific; do not copy development resource IDs into staging documentation. Review its contents before committing, and do not put credentials or secrets in Terraform outputs.
