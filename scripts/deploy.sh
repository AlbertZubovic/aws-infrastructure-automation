#!/usr/bin/env bash

set -euo pipefail

# Config
AWS_REGION="${AWS_REGION:-us-east-1}"
KEY_NAME="${KEY_NAME:-a2-key3}"

TF_STATE_BUCKET="${TF_STATE_BUCKET:-a2-tf-state-s4007755}"
TF_LOCK_TABLE="${TF_LOCK_TABLE:-a2-tf-locks-s4007755}"
TF_STATE_KEY="${TF_STATE_KEY:-terraform.tfstate}"

ANSIBLE_SSH_KEY="${ANSIBLE_SSH_KEY:-$HOME/.ssh/${KEY_NAME}.pem}"
KEY_PATH="$ANSIBLE_SSH_KEY"


# Paths
BOOTSTRAP_DIR="terraform/bootstrap"
ROOT_DIR="terraform"
ANSIBLE_DIR="ansible"
ANSIBLE_INV="${ANSIBLE_DIR}/inventory.ini"

# Helpers
log()  { printf "\n\033[1;36m==> %s\033[0m\n" "$*"; }
warn() { printf "\n\033[1;33mWARN:\033[0m %s\n" "$*" >&2; }
die()  { printf "\n\033[1;31mERROR:\033[0m %s\n" "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null || die "Missing '$1' in PATH"; }

# Fail fast if AWS creds invalid
check_creds() {
  aws sts get-caller-identity >/dev/null 2>&1 \
    || die "AWS credentials not valid. Re authenticate and re run."
}

# Import a resource into state if not already present
imp() {
  local addr="$1" id="$2"
  terraform state show "$addr" >/dev/null 2>&1 || terraform import "$addr" "$id"
}

# Frontend rows:
jq_frontend_rows() {
  jq -r '
    .Reservations[].Instances[] |
    select(.PublicIpAddress != null) |
    "\(.PrivateIpAddress) \(.PublicIpAddress)"
  '
}

# Private only rows:
jq_private_rows() {
  jq -r '
    .Reservations[].Instances[] |
    select(.PrivateIpAddress != null) |
    "\(.PrivateIpAddress)"
  '
}


# Pre flight
preflight() {
  need terraform
  need aws
  need jq
  need curl
  need ansible-galaxy || true
  check_creds

  [[ -f "$ANSIBLE_SSH_KEY" ]] || die "SSH key not found: $ANSIBLE_SSH_KEY"
  chmod 600 "$ANSIBLE_SSH_KEY" || true
}

# Terraform: Bootstrap
tf_bootstrap() {
  log "Bootstrap: terraform init (local backend)"
  terraform -chdir="$BOOTSTRAP_DIR" init -input=false

  log "Bootstrap: try importing existing bucket/table"
  (
    set -euo pipefail
    cd "$BOOTSTRAP_DIR"

    export TF_VAR_aws_region="$AWS_REGION"
    export TF_VAR_state_bucket_name="$TF_STATE_BUCKET"
    export TF_VAR_state_table_name="$TF_LOCK_TABLE"

    # S3 bucket
    if aws s3api head-bucket --bucket "$TF_STATE_BUCKET" 2>/dev/null; then
      imp aws_s3_bucket.tf_state "$TF_STATE_BUCKET"

      # Public Access Block
      if aws s3api get-public-access-block --bucket "$TF_STATE_BUCKET" >/dev/null 2>&1; then
        imp aws_s3_bucket_public_access_block.tf_state "$TF_STATE_BUCKET"
      fi

      # Versioning
      local ver_status
      ver_status="$(aws s3api get-bucket-versioning --bucket "$TF_STATE_BUCKET" \
        --query 'Status' --output text 2>/dev/null || true)"
      if [[ "$ver_status" == "Enabled" || "$ver_status" == "Suspended" ]]; then
        imp aws_s3_bucket_versioning.tf_state "$TF_STATE_BUCKET"
      fi

      # SSE
      if aws s3api get-bucket-encryption --bucket "$TF_STATE_BUCKET" >/dev/null 2>&1; then
        imp aws_s3_bucket_server_side_encryption_configuration.tf_state "$TF_STATE_BUCKET"
      fi
    fi

    # DynamoDB table
    if aws dynamodb describe-table --table-name "$TF_LOCK_TABLE" --region "$AWS_REGION" >/dev/null 2>&1; then
      imp aws_dynamodb_table.tf_locks "$TF_LOCK_TABLE"
    fi
  )

  log "Bootstrap: terraform apply"
  terraform -chdir="$BOOTSTRAP_DIR" apply -auto-approve -input=false \
    -var "aws_region=$AWS_REGION" \
    -var "state_bucket_name=$TF_STATE_BUCKET" \
    -var "state_table_name=$TF_LOCK_TABLE"
}

# Terraform: Switch to remote backend and apply root infrastructure
tf_root() {
  check_creds
  log "Root: terraform init (S3 backend)"
  terraform -chdir="$ROOT_DIR" init -reconfigure -input=false \
    -backend-config="bucket=$TF_STATE_BUCKET" \
    -backend-config="key=$TF_STATE_KEY" \
    -backend-config="region=$AWS_REGION" \
    -backend-config="dynamodb_table=$TF_LOCK_TABLE" \
    -backend-config="encrypt=true"

  check_creds
  log "Root: terraform apply"
  terraform -chdir="$ROOT_DIR" apply -lock-timeout=5m -auto-approve -input=false \
    -var "key_name=$KEY_NAME"
}

# Outputs:
read_outputs() {
  FE_ALB="$(terraform -chdir="$ROOT_DIR" output -raw frontend_alb_dns)"
  BE_ALB="$(terraform -chdir="$ROOT_DIR" output -raw backend_alb_dns)"

  log "Infra outputs:
  FE ALB: $FE_ALB
  BE ALB: $BE_ALB (internal)
"
}


# Ansible: dependencies, inventory generation and run
ansible_setup() {
  if ! command -v ansible-galaxy >/dev/null; then
    die "Ansible is not installed. Install Ansible first."
  fi
  if ! ansible-galaxy collection list | grep -q community.docker; then
    log "Installing Ansible collection: community.docker"
    ansible-galaxy collection install -r "${ANSIBLE_DIR}/requirements.yml"
  fi
}


generate_inventory() {
  log "Generate Ansible inventory from current EC2 instances"
  mkdir -p "$ANSIBLE_DIR"

  # Discover instances by tags
  FE_JSON="$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=a2-frontend-ec2-*" "Name=instance-state-name,Values=running")"
  BE_JSON="$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=a2-backend-ec2-*"  "Name=instance-state-name,Values=running")"
  DB_JSON="$(aws ec2 describe-instances --region "$AWS_REGION" \
    --filters "Name=tag:Name,Values=a2-db-ec2" "Name=instance-state-name,Values=running")"

  # Choose frontend public IP as the bastion
  FE_JUMP_IP="$(echo "$FE_JSON" | jq -r '
      .Reservations[].Instances[] | select(.PublicIpAddress != null) | .PublicIpAddress
    ' | head -n1)"
  [[ -n "$FE_JUMP_IP" && "$FE_JUMP_IP" != "null" ]] || die "No frontend public IP found for ProxyJump"

  {
    # Bastion host
    echo "[bastion]"
    printf "%s ansible_user=ec2-user ansible_ssh_private_key_file=%s\n" "$FE_JUMP_IP" "$KEY_PATH"

    echo
    echo "[db]"
    echo "$DB_JSON" | jq_private_rows | \
      awk -v k="$KEY_PATH" '{printf "%s ansible_host=%s ansible_user=ec2-user ansible_ssh_private_key_file=%s\n",$1,$1,k}'

    echo
    echo "[backend]"
    DB_PRIV=$(echo "$DB_JSON" | jq -r '.Reservations[].Instances[] | .PrivateIpAddress' | head -n1)
    echo "$BE_JSON" | jq_private_rows | \
      awk -v k="$KEY_PATH" -v db="$DB_PRIV" '{printf "%s ansible_host=%s ansible_user=ec2-user ansible_ssh_private_key_file=%s db_private_ip=%s\n",$1,$1,k,db}'

    echo
    echo "[frontend]"
    echo "$FE_JSON" | jq_frontend_rows | \
      awk -v k="$KEY_PATH" -v be="$BE_ALB" '{printf "%s ansible_host=%s ansible_user=ec2-user ansible_ssh_private_key_file=%s backend_private_ip=%s\n",$1,$2,k,be}'

    echo
    echo "[db:vars]"
    printf "ansible_ssh_common_args='-o IdentitiesOnly=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=6 -o ConnectTimeout=25 -o ControlMaster=auto -o ControlPersist=60s -o ProxyCommand=\"ssh -o IdentitiesOnly=yes -i %s -W %%h:%%p ec2-user@%s\"'\n" \
      "$KEY_PATH" "$FE_JUMP_IP"

    echo
    echo "[backend:vars]"
    printf "ansible_ssh_common_args='-o IdentitiesOnly=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=6 -o ConnectTimeout=25 -o ControlMaster=auto -o ControlPersist=60s -o ProxyCommand=\"ssh -o IdentitiesOnly=yes -i %s -W %%h:%%p ec2-user@%s\"'\n" \
      "$KEY_PATH" "$FE_JUMP_IP"
  } > "$ANSIBLE_INV"

  log "Inventory written to $ANSIBLE_INV"
  cat "$ANSIBLE_INV"
}


trust_hosts() {
  log "Trust host keys (frontends)"
  touch ~/.ssh/known_hosts
  awk '/^\[frontend\]/{f=1;next} /^\[/{f=0} f && /ansible_host=/{for(i=1;i<=NF;i++){if($i ~ /ansible_host=/){split($i,a,"="); print a[2]}}}' "$ANSIBLE_INV" \
    | sort -u \
    | xargs -I{} sh -c 'ssh-keyscan -T 5 -H {} >> ~/.ssh/known_hosts 2>/dev/null || true'
  chmod 600 ~/.ssh/known_hosts
}


run_ansible() {
  log "Run Ansible"
  ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_SSH_ARGS="-o IdentitiesOnly=yes" \
  ansible-playbook -i "$ANSIBLE_INV" "${ANSIBLE_DIR}/playbook.yml" \
    -e "backend_alb_dns=${BE_ALB}"
}


# Smoke test (Frontend ALB)
smoke_test() {
  log "Smoke check against FE ALB: http://$FE_ALB"
  local ok=false
  for i in {1..20}; do
    if curl -sSfI --max-time 5 "http://$FE_ALB" >/dev/null; then
      ok=true; break
    fi
    echo "frontend not ready yet, retrying ($i/20)…"
    sleep 6
  done
  $ok || die "Frontend failed health check"
  log "Done. Visit: http://$FE_ALB"
}

# Main
main() {
  preflight
  tf_bootstrap
  tf_root
  read_outputs
  ansible_setup
  generate_inventory
  trust_hosts
  run_ansible
  smoke_test
}

main "$@"
