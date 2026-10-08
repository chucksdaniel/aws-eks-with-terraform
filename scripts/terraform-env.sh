#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: bash scripts/terraform-env.sh <show|init|plan|apply|output|destroy> [terraform arguments...]\n' >&2
  exit 2
}

[[ $# -ge 1 ]] || usage

action="$1"
shift
case "$action" in
  show|init|plan|apply|output|destroy) ;;
  *) usage ;;
esac

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repository_root"

environment="$(git branch --show-current)"
case "$environment" in
  dev|staging) ;;
  *)
    printf 'Unsupported or detached Git branch: %s. Check out the dev or staging branch first.\n' \
      "${environment:-<detached HEAD>}" >&2
    exit 1
    ;;
esac

variable_file="environments/${environment}.tfvars"
if [[ ! -f "$variable_file" ]]; then
  if [[ "$environment" == "dev" && -f "terraform.tfvars" ]]; then
    variable_file="terraform.tfvars"
  else
    printf 'Missing %s. Create it from environments/%s.tfvars.example and review its values.\n' \
      "$variable_file" "$environment" >&2
    exit 1
  fi
fi

file_environment="$(awk -F= '
  /^[[:space:]]*environment[[:space:]]*=/ {
    value = $2
    gsub(/^[[:space:]\"]+|[[:space:]\"]+$/, "", value)
    print value
    exit
  }
' "$variable_file")"

if [[ "$file_environment" != "$environment" ]]; then
  printf 'Environment mismatch: requested %s but %s declares %s.\n' \
    "$environment" "$variable_file" "${file_environment:-<missing>}" >&2
  exit 1
fi

printf 'Environment: %s\n' "$environment"
printf 'Terraform state key: %s/eks-env/terraform.tfstate\n' "$environment"
printf 'Variable file: %s\n' "$variable_file"
printf 'Runbook: knowledge-base/DEPLOYMENT-RUNBOOK.md\n'
printf 'Limitations: knowledge-base/LIMITATIONS.md\n'

if [[ "$action" == "show" ]]; then
  exit 0
fi

terraform init -reconfigure \
  -backend-config="key=${environment}/eks-env/terraform.tfstate"

if [[ "$action" == "init" ]]; then
  exit 0
fi

terraform validate
if [[ "$action" == "output" ]]; then
  terraform output | tee knowledge-base/output.md
  exit 0
fi

terraform "$action" -var-file="$variable_file" "$@"
