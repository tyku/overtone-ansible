#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

ansible-inventory -i inventories/production/hosts.example.yml --graph >/dev/null
ansible-inventory -i inventories/production/hosts.example.yml --list >/dev/null
ansible-inventory -i inventories/bootstrap/hosts.example.yml --graph >/dev/null
ansible-inventory -i inventories/bootstrap/hosts.example.yml --list >/dev/null

for playbook in playbooks/*.yml; do
  case "$playbook" in
    playbooks/00-bootstrap.yml)
      inventory=inventories/bootstrap/hosts.example.yml
      ;;
    *)
      inventory=inventories/production/hosts.example.yml
      ;;
  esac

  ansible-playbook -i "$inventory" "$playbook" --syntax-check
  ansible-playbook -i "$inventory" "$playbook" --list-hosts >/dev/null
  ansible-playbook -i "$inventory" "$playbook" --list-tasks >/dev/null
done
