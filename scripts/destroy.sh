set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-academy}"
AWS_REGION="${AWS_REGION:-us-east-1}"
KEY_NAME="${KEY_NAME:-a2-key3}"
DRY_RUN="${DRY_RUN:-0}"

export AWS_PROFILE AWS_REGION

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
pushd "$TF_DIR" >/dev/null

terraform init -input=false -upgrade >/dev/null

if [[ "$DRY_RUN" == "1" || "${1:-}" == "--plan" ]]; then
  echo "--Dry Run--"
  terraform plan -destroy -var "key_name=${KEY_NAME}"
else
  echo "--Real Destroy--"
  terraform destroy -auto-approve -var "key_name=${KEY_NAME}"
fi

popd >/dev/null
