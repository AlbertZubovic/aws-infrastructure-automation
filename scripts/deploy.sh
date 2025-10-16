#!/usr/bin/env bash
set -euo pipefail

# Config
AWS_REGION="${AWS_REGION:-us-east-1}"
KEY_NAME="${KEY_NAME:-a2-key3}"

TF_STATE_BUCKET="${TF_STATE_BUCKET:-a2-tf-state-s4007755}"
TF_LOCK_TABLE="${TF_LOCK_TABLE:-a2-tf-locks-s4007755}"
TF_STATE_KEY="${TF_STATE_KEY:-terraform.tfstate}"

ANSIBLE_SSH_KEY="${ANSIBLE_SSH_KEY:-$HOME/.ssh/${KEY_NAME}.pem}"

# Helpers
log() { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }
die() { printf "\n\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null || die "Missing '$1' in PATH"; }

check_creds() {
  # Fail fast if AWS creds invalid
  aws sts get-caller-identity >/dev/null 2>&1 || {
    die "AWS credentials not valid. Re authenticate and re run."
  }
}

imp() {
  local addr="$1" id="$2"
  terraform state show "$addr" >/dev/null 2>&1 || terraform import "$addr" "$id"
}

# Pre flight
need terraform
need aws
need jq
need ansible-galaxy || true
check_creds

[[ -f "$ANSIBLE_SSH_KEY" ]] || die "SSH key not found"
chmod 600 "$ANSIBLE_SSH_KEY" || true

# Bootstrap (local state)
log "Bootstrap: terraform init (local backend)"
terraform -chdir=terraform/bootstrap init -input=false

log "Bootstrap: try importing existing bucket/table"
(
  set -euo pipefail
  cd terraform/bootstrap

  export TF_VAR_aws_region="$AWS_REGION"
  export TF_VAR_state_bucket_name="$TF_STATE_BUCKET"
  export TF_VAR_state_table_name="$TF_LOCK_TABLE"

  # Attempt imports if they already exist
  if aws s3api head-bucket --bucket "$TF_STATE_BUCKET" 2>/dev/null; then
    imp aws_s3_bucket.tf_state "$TF_STATE_BUCKET"

    # Public Access Block
    if aws s3api get-public-access-block --bucket "$TF_STATE_BUCKET" >/dev/null 2>&1; then
      imp aws_s3_bucket_public_access_block.tf_state "$TF_STATE_BUCKET"
    fi

    # Versioning
    VER_STATUS="$(aws s3api get-bucket-versioning --bucket "$TF_STATE_BUCKET" --query 'Status' --output text 2>/dev/null || true)"
    if [[ "$VER_STATUS" == "Enabled" || "$VER_STATUS" == "Suspended" ]]; then
      imp aws_s3_bucket_versioning.tf_state "$TF_STATE_BUCKET"
    fi

    # SSE
    if aws s3api get-bucket-encryption --bucket "$TF_STATE_BUCKET" >/dev/null 2>&1; then
      imp aws_s3_bucket_server_side_encryption_configuration.tf_state "$TF_STATE_BUCKET"
    fi
  fi

  if aws dynamodb describe-table --table-name "$TF_LOCK_TABLE" --region "$AWS_REGION" >/dev/null 2>&1; then
    imp aws_dynamodb_table.tf_locks "$TF_LOCK_TABLE"
  fi
)

log "Bootstrap: terraform apply"
terraform -chdir=terraform/bootstrap apply -auto-approve -input=false \
  -var "aws_region=$AWS_REGION" \
  -var "state_bucket_name=$TF_STATE_BUCKET" \
  -var "state_table_name=$TF_LOCK_TABLE"

# Root: switch to remote backend
check_creds
log "Root: terraform init (S3 backend)"
terraform -chdir=terraform init -reconfigure -input=false \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="key=$TF_STATE_KEY" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="dynamodb_table=$TF_LOCK_TABLE" \
  -backend-config="encrypt=true"

# Root: apply infra
check_creds
log "Root: terraform apply"
terraform -chdir=terraform apply -lock-timeout=5m -auto-approve -input=false \
  -var "key_name=$KEY_NAME"

# Read outputs
DB_PUB="$(terraform -chdir=terraform output -raw db_public_ip)"
DB_PRIV="$(terraform -chdir=terraform output -raw db_private_ip)"
BE_PUB="$(terraform -chdir=terraform output -raw backend_public_ip)"
BE_PRIV="$(terraform -chdir=terraform output -raw backend_private_ip)"
FE_PUB="$(terraform -chdir=terraform output -raw frontend_public_ip)"
FE_PRIV="$(terraform -chdir=terraform output -raw frontend_private_ip || true)"
FE_ALB="$(terraform -chdir=terraform output -raw frontend_alb_dns)"
BE_ALB="$(terraform -chdir=terraform output -raw backend_alb_dns)"

log "Infra outputs:
  DB    pub=$DB_PUB  priv=$DB_PRIV
  BE    pub=$BE_PUB  priv=$BE_PRIV
  FE    pub=$FE_PUB  priv=${FE_PRIV:-n/a}
  FE ALB: $FE_ALB
  BE ALB: $BE_ALB (internal)
"

# 4) Ansible: deps, inventory, deploy
check_creds
if ! ansible-galaxy collection list | grep -q community.docker; then
  log "Installing Ansible collection: community.docker"
  ansible-galaxy collection install -r ansible/requirements.yml
fi

log "Generate Ansible inventory from current EC2 instances"
INV="ansible/inventory.ini"
mkdir -p ansible

# Discover instances by tags
FE_JSON="$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=a2-frontend-ec2-*" "Name=instance-state-name,Values=running")"
BE_JSON="$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=a2-backend-ec2-*"  "Name=instance-state-name,Values=running")"
DB_JSON="$(aws ec2 describe-instances --region "$AWS_REGION" \
  --filters "Name=tag:Name,Values=a2-db-ec2" "Name=instance-state-name,Values=running")"

jq_hosts () { jq -r '.Reservations[].Instances[] | select(.PublicIpAddress != null) | "\(.PrivateIpAddress) \(.PublicIpAddress)"'; }

{
  echo "[db]"
  echo "$DB_JSON" | jq_hosts | awk -v k="$ANSIBLE_SSH_KEY" '{printf "%s ansible_host=%s ansible_user=ec2-user ansible_ssh_private_key_file=%s\n",$1,$2,k}'

  echo
  echo "[backend]"
  echo "$BE_JSON" | jq_hosts | awk -v k="$ANSIBLE_SSH_KEY" -v db="$DB_PRIV" '{printf "%s ansible_host=%s ansible_user=ec2-user ansible_ssh_private_key_file=%s db_private_ip=%s\n",$1,$2,k,db}'

  echo
  echo "[frontend]"
  BE_ENDPOINT="$BE_ALB"
  if [[ -z "$BE_ENDPOINT" || "$BE_ENDPOINT" == "null" ]]; then
    BE_ENDPOINT="$(echo "$BE_JSON" | jq -r '.Reservations[].Instances[0].PrivateIpAddress')"
  fi
  echo "$FE_JSON" | jq_hosts | awk -v k="$ANSIBLE_SSH_KEY" -v be="$BE_ENDPOINT" '{printf "%s ansible_host=%s ansible_user=ec2-user ansible_ssh_private_key_file=%s backend_private_ip=%s\n",$1,$2,k,be}'
} > "$INV"

log "Inventory written to $INV"
cat "$INV"

log "Trust host keys"
touch ~/.ssh/known_hosts
awk '/ansible_host=/{for(i=1;i<=NF;i++){if($i ~ /ansible_host=/){split($i,a,"="); print a[2]}}}' "$INV" \
  | sort -u \
  | xargs -I{} sh -c 'ssh-keyscan -T 5 -H {} >> ~/.ssh/known_hosts 2>/dev/null || true'
chmod 600 ~/.ssh/known_hosts

log "Run Ansible"
ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_SSH_ARGS="-o IdentitiesOnly=yes" \
ansible-playbook -i "$INV" ansible/playbook.yml

# 5) Smoke test (Frontend ALB)
log "Smoke check against FE ALB: http://$FE_ALB"
ok=false
for i in {1..20}; do
  if curl -sSfI --max-time 5 "http://$FE_ALB" >/dev/null; then
    ok=true; break
  fi
  echo "frontend not ready yet, retrying ($i/20)…"
  sleep 6
done
$ok || die "Frontend failed health check"

log "Done. Visit: http://$FE_ALB"
