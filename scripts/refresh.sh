#!/usr/bin/env bash
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-academy}"
AWS_REGION="${AWS_REGION:-us-east-1}"
KEY_NAME="${KEY_NAME:-a2-key3}"
export AWS_PROFILE AWS_REGION

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
ANS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../ansible" && pwd)"
INV="${ANS_DIR}/inventory.ini"

pushd "$TF_DIR" >/dev/null
terraform init -input=false -upgrade >/dev/null

if ! terraform apply -refresh-only -auto-approve -input=false -var "key_name=${KEY_NAME}" >/dev/null 2>&1; then
  echo "Warn: terraform refresh only failed."
fi

IP="$(terraform output -raw app_public_ip 2>/dev/null || true)"
popd >/dev/null

if [[ -z "${IP}" && -f "$INV" ]]; then
  IP="$(awk 'NF && $1 !~ /^\[/ && $1 ~ /^[0-9.]+$/ { print $1; exit }' "$INV" 2>/dev/null || true)"
fi

if [[ -z "${IP}" ]]; then
  echo "Error: Could not determine app_public_ip." >&2
  exit 1
fi

cat > "$INV" <<EOF
[app]
$IP ansible_user=ec2-user ansible_ssh_private_key_file=~/.ssh/${KEY_NAME}.pem ansible_python_interpreter=/usr/bin/python3 ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
EOF

echo "EC2 IP: $IP"
echo "Inventory written to $INV"
