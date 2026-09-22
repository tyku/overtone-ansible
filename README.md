# Overtone Ansible

Ansible-описание пяти существующих VPS:

- `bastion` — ограниченный SSH gateway;
- `haproxy` — отдельный TCP-балансировщик 80/443;
- `manager-1`, `worker-1`, `worker-2` — Docker Swarm.

Приложение, PostgreSQL, S3, TLS и Docker Stack здесь не настраиваются.

Текущие firewall и SSH-настройки сначала были выполнены вручную. Playbook’и
`20-firewall.yml` и `30-ssh-policy.yml` воспроизводят это состояние на случай
пересоздания серверов. Само наличие файлов ничего на VPS не изменяет.

## Административные пользователи

- `haproxy` → `overtone_haproxy`;
- `manager-1` → `overtone_manager-1`;
- `worker-1` → `overtone_worker-1`;
- `worker-2` → `overtone_worker-2`;
- bastion сохраняет уже настроенного пользователя из `overtone-bastion`.

Один публичный административный ключ может быть установлен всем этим
пользователям. Приватный ключ остаётся только на Mac.

## Playbook’и

| Playbook | Назначение |
| --- | --- |
| `00-bootstrap.yml` | Создаёт `overtone_*`, устанавливает публичный ключ и passwordless sudo. Не меняет SSH/firewall. |
| `10-system-baseline.yml` | Hostname, базовые пакеты, time sync и unattended security updates без automatic reboot. |
| `20-firewall.yml` | Воспроизводит role-specific UFW policy. Требует явного подтверждения. |
| `30-ssh-policy.yml` | Воспроизводит три SSH-профиля с проверкой и rollback. Требует явного подтверждения. |
| `40-docker.yml` | Устанавливает зафиксированную версию Docker на Swarm-узлы. |
| `50-swarm.yml` | Создаёт manager и присоединяет workers через приватную сеть. |
| `60-haproxy.yml` | Устанавливает HAProxy и проксирует TCP 80/443 на workers. |
| `70-team-access.yml` | Управляет полноправными администраторами: ключи, sudo и AllowUsers. |
| `71-tunnel-accounts.yml` | Создаёт ограниченные tunnel identities на bastion и выбранном worker. |
| `90-audit.yml` | Read-only аудит эффективных SSH/UFW-настроек. |

## Управление дополнительным доступом

Полный желаемый список пользователей хранится только в игнорируемом
`inventories/production/hosts.yml`, в `all.vars`. Пример структуры находится в
`hosts.example.yml`. Не удаляйте из списка действующего пользователя: список
используется как desired state для `AllowUsers`.

`70-team-access.yml` создаёт указанного пользователя на выбранных `hosts`,
устанавливает только его перечисленные публичные ключи, блокирует пароль и даёт
passwordless sudo. Поле `hosts` — точный желаемый набор: на остальных пяти
управляемых VPS аккаунт с этим именем будет удалён. Приватный ключ Ansible не
получает и на bastion не копирует.

Сначала check mode на bastion:

```bash
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/70-team-access.yml \
  --limit bastion \
  -e access_policy_confirmed=true \
  --check --diff
```

После проверки реального входа нового администратора playbook можно применить к
остальным хостам без `--limit`. Для полного удаления устанавливается
`state: absent`; запись следует удалить из файла только после успешного удаления
аккаунта со всех VPS.

`71-tunnel-accounts.yml` создаёт одну техническую identity на всех нужных хопах:

- на bastion ключ может открыть только TCP-соединения к SSH выбранных workers;
- на каждом выбранном worker ключ может использовать только remote forwarding и перечисленные
  loopback `permit_listen` endpoints;
- password, интерактивная shell, PTY, agent/X11 forwarding и sudo отсутствуют.

Одна запись может обслуживать оба worker: `target_hosts` содержит `worker-1` и
`worker-2`, а пользователь, например `overtone_tunnel`, создаётся на bastion и
обоих workers. Один ключ проще в эксплуатации, но его отзыв одновременно
отключает оба направления.

Первый check mode:

```bash
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/71-tunnel-accounts.yml \
  --limit bastion \
  -e access_policy_confirmed=true \
  --check --diff
```

Затем playbook применяется ко всей своей группе: bastion и workers. На
невыбранных workers одноимённая managed identity удаляется, поэтому изменение
`target_hosts` не оставляет старый аккаунт. Playbook не запускает и не поддерживает
сам туннель. Пример ручного подключения:

```bash
ssh -i ~/.ssh/overtone-infra/keys/CHANGE_ME_TUNNEL_KEY \
  -o IdentitiesOnly=yes \
  -J overtone_tunnel@BASTION_PUBLIC_IP \
  -N -R 127.0.0.1:19000:127.0.0.1:9000 \
  overtone_tunnel@WORKER_PRIVATE_IP
```

Для нового Unix-пользователя `--check` не может проверить запись его
`authorized_keys`, потому что домашней директории ещё нет. Реальный запуск
создаёт пользователя первым и затем устанавливает ключ.

## Зафиксированная модель доступа

### Bastion

- публичный SSH только с `firewall_admin_public_cidr`;
- `PasswordAuthentication no`, `PermitRootLogin no`;
- agent/X11/tunnel forwarding запрещены;
- разрешён только `local` forwarding;
- `PermitOpen` содержит приватные IP четырёх внутренних VPS на TCP 22;
- приватных пользовательских ключей на bastion нет.

### HAProxy и manager

- SSH только с приватного IP bastion;
- root/password login запрещены;
- весь SSH forwarding запрещён через `DisableForwarding yes`;
- HAProxy принимает публичные TCP 80/443;
- manager принимает TCP 2377 от workers.

### Workers

- SSH только с приватного IP bastion;
- TCP 80/443 только с приватного IP HAProxy;
- root/password/agent/X11/tunnel forwarding запрещены;
- разрешён только `remote` forwarding (`ssh -R`);
- `GatewayPorts no`;
- `PermitListen` ограничен `127.0.0.1:19000–19002`.

### Swarm private network

Между Swarm-узлами разрешены:

- TCP/UDP 7946;
- UDP 4789;
- ESP, IP protocol 50;
- TCP 2377 только на manager со стороны workers.

UFW не является единственной защитой опубликованных Docker-портов: Docker может
обходить обычные UFW chains. Внешний firewall/security groups провайдера остаётся
обязательным и этим проектом не управляется.

## Что ещё нужно заполнить

Проверьте все placeholders:

```bash
cd /Users/artemkud/dev/overtone-ansible
rg -n 'CHANGE_ME' . --glob '!.collections/**' --glob '!.git/**'
```

Сейчас ожидаются:

1. Игнорируемый `inventories/production/hosts.yml`:
   - приватные IP bastion, HAProxy, manager и workers;
   - приватные `ansible_host` внутренних VPS;
   - реальный bastion username для `AllowUsers`;
   - ваш публичный IPv4 `/32` для UFW.
2. `inventories/production/group_vars/swarm.yml`:
   - точная версия Docker после настройки официального repository.

Проверьте, что интерфейсы действительно называются `eth0` и `eth1`. Если это не
так, измените `public_interface` и `private_interface` в
`inventories/production/group_vars/all.yml`.

## Локальная подготовка

```bash
cd /Users/artemkud/dev/overtone-ansible
ansible-galaxy collection install -r requirements.yml -p .collections
```

Ansible использует отдельный known_hosts:

```text
~/.ssh/overtone-infra/known_hosts
```

Host key checking включён. `StrictHostKeyChecking=no` не используется.

## Проверки без подключения к VPS

Эти команды только читают локальные YAML-файлы:

```bash
ansible-inventory -i inventories/production/hosts.yml --graph

for playbook in playbooks/*.yml; do
  case "$playbook" in
    playbooks/00-bootstrap.yml) inventory=inventories/bootstrap/hosts.yml ;;
    *) inventory=inventories/production/hosts.yml ;;
  esac

  ansible-playbook -i "$inventory" "$playbook" --syntax-check
  ansible-playbook -i "$inventory" "$playbook" --list-hosts
  ansible-playbook -i "$inventory" "$playbook" --list-tasks
done
```

`90-audit.yml` тоже ничего не изменяет, но уже подключается к VPS и выполняет
read-only команды `sshd -t`, `sshd -T`, `ufw status` и `ufw show added`:

```bash
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/90-audit.yml --limit haproxy
```

## Безопасное принятие существующего firewall под управление Ansible

`20-firewall.yml` работает additively:

- добавляет отсутствующие разрешающие правила;
- выставляет default deny incoming / allow outgoing;
- включает UFW;
- не выполняет `ufw reset`;
- не удаляет неизвестные или старые правила автоматически.

Поэтому он безопаснее для первоначального adoption, но лишние старые правила
потребуется удалять отдельным явным изменением.

Сначала один сервер в check mode:

```bash
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/20-firewall.yml \
  --limit haproxy \
  -e access_policy_confirmed=true \
  --check
```

Перед реальным применением необходимо сохранить текущую SSH-сессию и открыть
консоль провайдера. Реальный запуск без `--check` сейчас не требуется.

## Безопасное принятие существующей SSH policy

`30-ssh-policy.yml` управляет теми же файлами, которые создавались вручную:

```text
/etc/ssh/sshd_config.d/00-overtone-bastion.conf
/etc/ssh/sshd_config.d/00-overtone-internal.conf
```

Профили:

- `bastion` — local forwarding и точный `PermitOpen`;
- `locked` — HAProxy/manager, forwarding полностью запрещён;
- `worker` — только remote forwarding и точный `PermitListen`.

Playbook:

- работает с `serial: 1`;
- сохраняет существующий drop-in;
- проверяет новый фрагмент;
- выполняет полный `sshd -t`;
- восстанавливает предыдущий файл при ошибке;
- использует reload вместо restart.

Первоначально только check mode и один host:

```bash
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/30-ssh-policy.yml \
  --limit haproxy \
  -e access_policy_confirmed=true \
  --check --diff
```

Форматирование созданного вручную файла может отличаться от шаблона, поэтому
Ansible способен показать diff даже при эквивалентной эффективной политике.

## System baseline

`10-system-baseline.yml` устанавливает базовые пакеты, time sync и unattended
security updates. Automatic reboot отключён.

```bash
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/10-system-baseline.yml --limit haproxy --check --diff
```

Проверка unattended-upgrades на сервере:

```bash
systemctl list-timers 'apt-daily*'
sudo unattended-upgrade --dry-run --debug
sudo journalctl -u unattended-upgrades --since today
```

## Docker, Swarm и HAProxy

Эти этапы пока сохранены отдельно:

```text
40-docker.yml
50-swarm.yml
60-haproxy.yml
```

Docker repository и установка разделены tags:

```bash
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/40-docker.yml --limit manager-1 --tags docker_repo

ansible-playbook -i inventories/production/hosts.yml \
  playbooks/40-docker.yml --limit manager-1 --tags docker_install
```

Перед `docker_install` необходимо записать одну точную доступную версию Docker в
`docker_ce_version`. Членство в группе `docker` фактически предоставляет
root-права.

Swarm join token считывается только в память Ansible, скрыт через `no_log` и не
записывается в inventory или файлы.

HAProxy настроен как TCP-прокси 80/443 без TLS termination. Пока на workers нет
сервисов на этих портах, backend health checks ожидаемо будут показывать `DOWN`.
