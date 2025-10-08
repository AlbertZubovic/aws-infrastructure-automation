#!/usr/bin/env bash
set -euo pipefail

AWS_PROFILE="${AWS_PROFILE:-academy}"
AWS_REGION="${AWS_REGION:-us-east-1}"
KEY_NAME="${KEY_NAME:-a2-key3}"
REQUIRED_TF="1.6.0"

TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"
ANS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../ansible" && pwd)"
INV="${ANS_DIR}/inventory.ini"
PEM="$HOME/.ssh/${KEY_NAME}.pem"

export AWS_PROFILE AWS_REGION

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "Missing command: $1" >&2; exit 1; }; }
ver_ge() { [ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

need_cmd aws
need_cmd terraform
need_cmd ansible
need_cmd curl

if [ -d "$HOME/.tfenv/bin" ] && ! command -v tfenv >/dev/null 2>&1; then
  export PATH="$HOME/.tfenv/bin:$PATH"
fi

check_tf() {
  local tfv
  tfv="$(terraform -version | head -n1 | sed -E 's/[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
  echo "Terraform version: $tfv"
  ver_ge "$tfv" "$REQUIRED_TF"
}
if ! check_tf; then
  if command -v tfenv >/dev/null 2>&1; then
    echo "Upgrading Terraform to >= $REQUIRED_TF via tfenv..."
    tfenv install "$REQUIRED_TF" >/dev/null || true
    tfenv use "$REQUIRED_TF" >/dev/null
    hash -r 2>/dev/null || true
    if ! check_tf; then
      echo "Error: Terraform is still < $REQUIRED_TF after tfenv. Ensure PATH contains ~/.tfenv/bin." >&2
      exit 1
    fi
  else
    echo "Error: Terraform < $REQUIRED_TF. Install/upgrade Terraform or install tfenv:" >&2
    exit 1
  fi
fi

if ! aws sts get-caller-identity >/dev/null 2>&1; then
  cat >&2 <<EOF
Error: AWS credentials for profile '$AWS_PROFILE' are missing/expired.
EOF
  exit 1
fi

if ! aws ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  echo "Creating key pair '$KEY_NAME' and saving PEM to $PEM"
  umask 077
  aws ec2 create-key-pair --key-name "$KEY_NAME" --query KeyMaterial --output text > "$PEM"
  chmod 600 "$PEM"
fi
[[ -f "$PEM" ]] || { echo "Missing PEM: $PEM" >&2; exit 1; }

pushd "$TF_DIR" >/dev/null
terraform init -input=false -upgrade >/dev/null
terraform apply -auto-approve -input=false -var "key_name=${KEY_NAME}" >/dev/null
IP="$(terraform output -raw app_public_ip || true)"
popd >/dev/null

if [[ -z "${IP:-}" ]]; then
  echo "Error: Could not read app_public_ip from Terraform outputs." >&2
  exit 1
fi

cat > "$INV" <<EOF
[app]
$IP ansible_user=ec2-user ansible_ssh_private_key_file=~/.ssh/${KEY_NAME}.pem ansible_python_interpreter=/usr/bin/python3 ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'
EOF

echo "EC2 IP: $IP"
echo "Inventory written to $INV"

ansible -i "$INV" app -m ping -vvv
ansible-playbook -i "$INV" "$ANS_DIR/playbook.yml"

echo "--HTTP--"
if curl -fsS "http://${IP}:8000/health" >/dev/null 2>&1; then
  echo "PASS: /health OK"
else
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://${IP}:8000/" || echo ERR)"
  echo "Fallback / => HTTP $code"
fi

echo "--Containers--"
ansible -b -i "$INV" app -m shell -a '
  LB="{"; RB="}";
  docker ps --format "table ${LB}${LB}.Names${RB}${RB}\t${LB}${LB}.Image${RB}${RB}\t${LB}${LB}.Status${RB}${RB}\t${LB}${LB}.Ports${RB}${RB}"
'
