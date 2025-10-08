#!/usr/bin/env bash
set -euo pipefail

TF_DIR="terraform"
ANS_INV="ansible/inventory.ini"

get_ip_from_tf() {
  if ! (cd "$TF_DIR" && terraform output -raw app_public_ip >/dev/null 2>&1); then
    (cd "$TF_DIR" && terraform init -input=false -upgrade >/dev/null 2>&1 || true)
  fi
  (cd "$TF_DIR" && terraform output -raw app_public_ip 2>/dev/null) || true
}

get_ip_from_inventory() {
  awk 'NF && $1 !~ /^\[/ && $1 ~ /^[0-9.]+$/ { print $1; exit }' "$ANS_INV" 2>/dev/null || true
}

IP="$(get_ip_from_tf)"
if [[ -z "${IP}" ]]; then
  IP="$(get_ip_from_inventory)"
fi

if [[ -z "${IP}" ]]; then
  echo "Error: Could not determine app_public_ip." >&2
  exit 1
fi

echo "IP=$IP"

echo "--HTTP--"
if curl -fsS "http://${IP}:8000/health" >/dev/null 2>&1; then
  echo "PASS: /health OK"
else
  code="$(curl -s -o /dev/null -w '%{http_code}' "http://${IP}:8000/" || echo ERR)"
  echo "Fallback / => HTTP $code"
fi

ansible -b -i ansible/inventory.ini app -m shell -a '
  LB="{"; RB="}";
  docker ps --format "table ${LB}${LB}.Names${RB}${RB}\t${LB}${LB}.Image${RB}${RB}\t${LB}${LB}.Status${RB}${RB}\t${LB}${LB}.Ports${RB}${RB}"
'

ansible -b -i ansible/inventory.ini app -m shell -a '
  docker network inspect posts_net >/dev/null && echo posts_net: OK
'

echo "--Backend logs--"
ansible -b -i "$ANS_INV" app -m shell -a 'docker logs --tail 30 posts_backend || true'
