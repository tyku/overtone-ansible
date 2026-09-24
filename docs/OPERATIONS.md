# Production operations

This project prepares the hosts; application deployment remains in
`overtone-infra`. Never run the commands below until the production inventory
has been reviewed and a provider console is available for SSH/firewall changes.

## 1. Local dependencies

```bash
cd /Users/artemkud/dev/overtone-ansible
ansible-galaxy collection install -r requirements.yml -p .collections
```

CI-only tools are listed in `requirements-ci.txt`.

## 2. Inventory and secrets

```bash
cp inventories/production/hosts.example.yml \
  inventories/production/hosts.yml
cp inventories/bootstrap/hosts.example.yml \
  inventories/bootstrap/hosts.yml
```

Both destination files are ignored. Fill host addresses, users and public keys
locally. Public keys may be stored in inventory; private keys must not be.

Only create a Vault file when Ansible genuinely needs a secret:

```bash
ansible-vault create inventories/production/vault.yml
```

The file is ignored and is not loaded automatically. Pass it explicitly with
`--extra-vars @inventories/production/vault.yml --ask-vault-pass`. Docker Hub
credentials used only by GitHub Actions belong in GitHub secrets, not in Vault.

## 3. Local validation

```bash
./scripts/check-secrets.sh
./scripts/validate-local.sh
ansible-inventory -i inventories/production/hosts.yml --graph
```

No command in this section connects to production.

## 4. Bootstrap

Bootstrap uses the provider-created account and password inventory. Run one host
at a time with `--ask-pass` and keep provider console access available:

```bash
ansible-playbook -i inventories/bootstrap/hosts.yml \
  playbooks/00-bootstrap.yml --limit manager-1 --ask-pass
```

Verify key-based access before moving to the next host. Bootstrap does not alter
sshd or firewall policy.

## 5. Baseline, firewall and SSH

Start with check mode and one host:

```bash
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/10-system-baseline.yml --limit manager-1 --check --diff

ansible-playbook -i inventories/production/hosts.yml \
  playbooks/20-firewall.yml --limit manager-1 \
  -e access_policy_confirmed=true --check --diff

ansible-playbook -i inventories/production/hosts.yml \
  playbooks/30-ssh-policy.yml --limit manager-1 \
  -e access_policy_confirmed=true --check --diff
```

For real SSH/firewall adoption, keep the existing session open, verify a second
session through bastion and apply without `--check` only after reviewing the diff.

## 6. Docker Engine

Configure an exact `docker_ce_version`, then install repository metadata first:

```bash
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/40-docker.yml --tags docker_repo

ansible-playbook -i inventories/production/hosts.yml \
  playbooks/40-docker.yml --tags docker_install --check --diff
```

The real `docker_install` run installs the same explicit version and holds
`docker-ce`/`docker-ce-cli`. Changing the inventory version is the explicit
upgrade action. Membership in the `docker` group is root-equivalent.

Read-only readiness checks:

```bash
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/45-docker-readiness.yml
```

The optional image pull probe is disabled until a non-`latest` reference is set.

## 7. Docker Swarm

For an existing manager, inspect and independently verify the current cluster ID:

```bash
ansible manager-1 -i inventories/production/hosts.yml -b \
  -m ansible.builtin.command \
  -a 'docker info --format={{.Swarm.Cluster.ID}}'
```

Record the value as `swarm_expected_id` in ignored `hosts.yml`. The playbook
refuses to adopt an active manager whose ID is empty or different. An active
worker must already be known to that manager; otherwise the playbook fails and
never runs `docker swarm leave`.

```bash
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/50-swarm.yml --check --diff

ansible-playbook -i inventories/production/hosts.yml \
  playbooks/50-swarm.yml
```

For a genuinely new inactive manager only:

```bash
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/50-swarm.yml -e swarm_initialize_confirmed=true --check --diff

ansible-playbook -i inventories/production/hosts.yml \
  playbooks/50-swarm.yml -e swarm_initialize_confirmed=true
```

Check mode can predict manager initialization but deliberately defers worker
joins and cluster verification because the manager does not yet exist. The real
run prints the new cluster ID; record it before the next run. Join tokens remain
in memory under `no_log`.

## 8. Inference tunnel networking

This stage is disabled by default and never creates the SSH tunnel. Follow
`docs/TUNNEL-NETWORKING.md` before enabling it.

## 9. HAProxy

```bash
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/60-haproxy.yml --limit haproxy --check --diff

ansible-playbook -i inventories/production/hosts.yml \
  playbooks/60-haproxy.yml --limit haproxy
```

The role validates with `haproxy -c`, reloads only after a changed valid config,
uses TCP passthrough and does not emit PROXY protocol. Before the gateway is
deployed, backend health checks may be DOWN.

## 10. CI deploy identity

Создайте отдельную пару ключей без passphrase только для GitHub Actions:

```bash
ssh-keygen -t ed25519 -a 64 \
  -f ~/.ssh/overtone-infra/keys/overtone-deploy \
  -C overtone_deploy
```

Приватный ключ не передаётся Ansible. Добавьте только содержимое файла
`overtone-deploy.pub` в игнорируемый `inventories/production/hosts.yml`:

```yaml
deploy_access_users:
  - name: overtone_deploy
    public_keys:
      - ssh-ed25519 REPLACE_WITH_PUBLIC_KEY github-actions
    target_host: manager-1
    state: present
```

Этот пользователь не получает sudo. На manager он входит в группу `docker`,
что фактически даёт root-equivalent доступ. На bastion тот же ключ может только
создать SSH-транзит к приватному адресу manager на TCP 22.

Сначала проверьте и примените только bastion, сохраняя текущую SSH-сессию и
консоль провайдера открытыми:

```bash
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/80-deploy-host.yml --limit bastion \
  -e access_policy_confirmed=true --check --diff

ansible-playbook -i inventories/production/hosts.yml \
  playbooks/80-deploy-host.yml --limit bastion \
  -e access_policy_confirmed=true
```

Проверьте существующий административный вход и транзит новым ключом. Затем
повторите check mode и реальный запуск только для manager:

```bash
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/80-deploy-host.yml --limit manager-1 \
  -e access_policy_confirmed=true --check --diff

ansible-playbook -i inventories/production/hosts.yml \
  playbooks/80-deploy-host.yml --limit manager-1 \
  -e access_policy_confirmed=true
```

Проверки на VPS:

```bash
getent passwd overtone_deploy
id overtone_deploy
sudo -l -U overtone_deploy
stat -c '%U %G %a %n' /opt/overtone-infra
sshd -t
sshd -T | grep -E '^(allowusers|passwordauthentication|permitrootlogin)'
```

На bastion `id` не должен показывать группу `docker`, а каталога
`/opt/overtone-infra` быть не должно. На manager группа `docker` ожидаема,
`sudo -l` должен отказать, каталог должен иметь владельца `overtone_deploy` и
режим `0750`. Финальная проверка с Mac:

```bash
ssh -i ~/.ssh/overtone-infra/keys/overtone-deploy \
  -o IdentitiesOnly=yes \
  -J overtone_deploy@BASTION_PUBLIC_IP \
  overtone_deploy@MANAGER_PRIVATE_IP \
  'docker version --format "{{.Server.Version}}"'
```

Новый аккаунт в `--check` ещё не существует, поэтому Ansible честно отложит
проверку его `authorized_keys` и владельца каталога до реального запуска.

## 11. Aggregate run

`site.yml` starts after bootstrap and includes CI deploy-user creation. It still
requires `access_policy_confirmed=true`, because firewall, SSH and Docker-group
changes are security-sensitive.

```bash
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/site.yml \
  -e access_policy_confirmed=true \
  --check --diff
```

Run independent stages first. Use the aggregate real run only after every stage
has been adopted successfully.

## 12. Idempotence

Run the same real playbook twice. The second recap should report `changed=0`.
Readiness playbooks are read-only except an explicitly enabled immutable image
pull probe, which may populate the local Docker cache on its first run.

## 13. Readiness and diagnostics

```bash
ansible-playbook -i inventories/production/hosts.yml playbooks/90-audit.yml
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/91-infrastructure-readiness.yml
```

Useful read-only Swarm diagnostics:

```bash
ansible manager-1 -i inventories/production/hosts.yml -b \
  -m ansible.builtin.command -a 'docker node ls'

ansible swarm -i inventories/production/hosts.yml -b \
  -m ansible.builtin.command -a 'docker info'
```

The optional PostgreSQL, S3, HAProxy backend and inference checks are enabled
only after their endpoints are configured. No database migrations or S3 writes
are performed.

## 14. Safe rollback

- SSH and HAProxy templates create backups and validate before reload.
- UFW adoption is additive and never resets the firewall.
- Revert the responsible inventory variable/template and rerun the single stage.
- Docker version rollback requires an explicit older `docker_ce_version`.
- Swarm topology is never rolled back automatically; investigate a partial
  cluster and recover it manually rather than forcing nodes to leave.
- No playbook removes Docker volumes, application networks or stacks.
