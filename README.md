# Overtone Ansible

Этот проект подготавливает пять существующих VPS:

- `bastion` — уже настроенная точка SSH-входа;
- `haproxy` — отдельный TCP-балансировщик портов 80/443;
- `manager-1`, `worker-1`, `worker-2` — Docker Swarm.

Приложение, PostgreSQL, S3, TLS и Docker Stack здесь не настраиваются.

## Что нужно заполнить

Найдите все оставшиеся заглушки:

```bash
rg -n 'CHANGE_ME' . --glob '!README.md'
```

Заполняются только локальные файлы:

1. `inventories/bootstrap/hosts.yml` — публичные IP, исходные пользователи и
   пути к исходным ключам провайдера.
2. `inventories/production/hosts.yml` — приватные IP четырёх внутренних VPS и
   приватный IP bastion.
3. `inventories/production/group_vars/swarm.yml` — точная версия Docker после
   подключения официального Docker-репозитория.

Не помещайте пароли, join tokens и приватные ключи в inventory. Если исходный
доступ использует пароль, удалите `ansible_ssh_private_key_file` для нужного
хоста и запускайте bootstrap с `--ask-pass`. Если sudo требует пароль, добавьте
`--ask-become-pass`.

## Локальная подготовка

Запускайте команды из корня этого проекта, иначе `ansible.cfg` может не быть
подхвачен.

```bash
cd /Users/artemkud/dev/overtone-ansible
ansible-galaxy collection install -r requirements.yml -p .collections
ansible --version
ansible-config dump --only-changed
```

`host_key_checking` включён. Все host keys хранятся в
`~/.ssh/overtone-infra/known_hosts`. Перед принятием нового ключа сравните его
fingerprint с данными в консоли провайдера. `ssh-keyscan` сам по себе не
подтверждает подлинность сервера.

## 1. Проверить bootstrap inventory

Команда читает inventory и не подключается к VPS:

```bash
ansible-inventory -i inventories/bootstrap/hosts.yml --graph
```

Проверка первоначального SSH-доступа к одной машине:

```bash
ansible -i inventories/bootstrap/hosts.yml haproxy -m ansible.builtin.ping
```

Продолжайте только если результат содержит `SUCCESS`.

## 2. Bootstrap внутренних серверов

Bootstrap создаёт `overtone`, блокирует его пароль, устанавливает только
публичный ключ и предоставляет passwordless sudo. Он не изменяет sshd,
root-login, парольную аутентификацию или firewall.

Предварительная проверка для одной машины:

```bash
ansible-playbook -i inventories/bootstrap/hosts.yml playbooks/00-bootstrap.yml \
  --limit haproxy --check --diff
```

Первый реальный запуск:

```bash
ansible-playbook -i inventories/bootstrap/hosts.yml playbooks/00-bootstrap.yml \
  --limit haproxy --diff
```

Затем проверьте новый вход в отдельном терминале, не закрывая старую сессию:

```bash
ssh -J overtone-bastion \
  -i ~/.ssh/overtone-infra/keys/overtone-production \
  -o UserKnownHostsFile=~/.ssh/overtone-infra/known_hosts \
  overtone@CHANGE_ME_HAPROXY_PRIVATE_IP
```

Проверьте `sudo -n true`. Только после успешной проверки повторите bootstrap с
`--limit manager-1`, затем `worker-1` и `worker-2`.

Откат bootstrap: через исходного пользователя или консоль провайдера удалить
`/etc/sudoers.d/overtone`, ключ из `/home/overtone/.ssh/authorized_keys` и при
необходимости пользователя. Не удаляйте пользователя до проверки, что он не
используется активной сессией.

## 3. Проверить production-доступ через bastion

Сначала заполните `inventories/production/hosts.yml`. Локальная SSH-секция
`overtone-bastion` уже существует и этим проектом не изменяется. Приватный ключ
никогда не копируется на bastion; `ProxyJump` выполняется локальным OpenSSH.

Для удобного ручного входа можно добавить в локальный
`~/.ssh/overtone-infra/config/hosts.conf` отдельные секции такого вида:

```sshconfig
Host overtone-manager-1
    HostName CHANGE_ME_MANAGER_1_PRIVATE_IP
    User overtone
    IdentityFile ~/.ssh/overtone-infra/keys/overtone-production
    IdentitiesOnly yes
    ProxyJump overtone-bastion
    UserKnownHostsFile ~/.ssh/overtone-infra/known_hosts
```

Аналогично создаются локальные aliases для HAProxy и обоих workers. Эти секции
находятся только на Mac и не копируют ключ на bastion.

```bash
ansible-inventory -i inventories/production/hosts.yml --graph
ansible -i inventories/production/hosts.yml internal -m ansible.builtin.ping
```

Продолжайте только когда все четыре внутренних сервера возвращают `SUCCESS`.

## 4. Общая настройка и security updates

`10-common.yml` задаёт hostname, ставит базовые пакеты и включает
`systemd-timesyncd`. Bastion получает только эти общие настройки; его SSH не
меняется.

```bash
ansible-playbook -i inventories/production/hosts.yml playbooks/10-common.yml \
  --limit haproxy --check --diff
ansible-playbook -i inventories/production/hosts.yml playbooks/10-common.yml \
  --limit haproxy --diff
```

После проверки применяйте к остальным узлам по одному.

Security updates устанавливаются отдельным этапом; автоматическая перезагрузка
отключена:

```bash
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/20-security-updates.yml --limit haproxy --check --diff
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/20-security-updates.yml --limit haproxy --diff
```

Проверка на сервере:

```bash
systemctl list-timers 'apt-daily*'
sudo unattended-upgrade --dry-run --debug
sudo journalctl -u unattended-upgrades --since today
```

Swarm-узлы при необходимости перезагружаются вручную и строго по одному.

## 5. SSH hardening внутренних серверов

Bastion исключён из `30-ssh-hardening.yml`. Перед каждым узлом сохраните одну
рабочую SSH-сессию и проверьте второй вход под `overtone` через bastion.

Проверка без применения:

```bash
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/30-ssh-hardening.yml --limit haproxy \
  -e ssh_hardening_confirmed=true --check --diff
```

Применение только к одному серверу:

```bash
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/30-ssh-hardening.yml --limit haproxy \
  -e ssh_hardening_confirmed=true --diff
```

Playbook сначала выполняет `sshd -t`, затем делает reload, а не restart. После
этого откройте новую сессию. Повторяйте по одному серверу.

Откат через консоль провайдера:

```bash
sudo mv /etc/ssh/sshd_config.d/00-overtone-hardening.conf \
  /etc/ssh/sshd_config.d/00-overtone-hardening.conf.disabled
sudo sshd -t
sudo systemctl restart ssh
```

Консоль провайдера должна оставаться доступной на всём этапе.

## 6. Firewall/security groups провайдера

Firewall провайдера является основным внешним барьером. UFW не используется как
единственная защита: опубликованные Docker-порты могут обходить его правила.

Нужны следующие правила:

- bastion: публичный TCP 22 только с вашего публичного IP `/32`;
- HAProxy: публичные TCP 80/443 от клиентов;
- внутренние четыре VPS: TCP 22 только с приватного IP bastion;
- между тремя Swarm-узлами: TCP 2377, TCP/UDP 7946, UDP 4789 и IP protocol 50;
- от HAProxy к `worker-1` и `worker-2`: приватные TCP 80/443;
- исходящий DNS/HTTP/HTTPS для пакетов и обновлений.

Публичный SSH внутренних серверов закрывается только после bootstrap,
production ping и SSH hardening. Меняйте правила по одному серверу и каждый раз
проверяйте вход через bastion.

## 7. Docker

Сначала настраивается официальный репозиторий без установки Docker:

```bash
ansible-playbook -i inventories/production/hosts.yml playbooks/40-docker.yml \
  --limit manager-1 --tags docker_repo --check --diff
ansible-playbook -i inventories/production/hosts.yml playbooks/40-docker.yml \
  --limit manager-1 --tags docker_repo --diff
```

На `manager-1` посмотрите доступные версии:

```bash
apt-cache madison docker-ce
```

Скопируйте одну точную строку версии в `docker_ce_version`, затем настройте
репозиторий на workers и установите эту же версию по одному узлу:

```bash
ansible-playbook -i inventories/production/hosts.yml playbooks/40-docker.yml \
  --tags docker_repo --diff
ansible-playbook -i inventories/production/hosts.yml playbooks/40-docker.yml \
  --limit manager-1 --tags docker_install --check --diff
ansible-playbook -i inventories/production/hosts.yml playbooks/40-docker.yml \
  --limit manager-1 --tags docker_install --diff
```

Повторите `docker_install` для каждого worker. Членство `overtone` в группе
`docker` фактически даёт root-права. Это сделано явно для ручного
администрирования; после изменения группы нужна новая SSH-сессия.

## 8. Docker Swarm

Playbook инициализирует manager на приватном адресе, получает worker join token
только в памяти Ansible и присоединяет workers по одному. Токен скрыт через
`no_log` и не записывается в inventory.

```bash
ansible-playbook -i inventories/production/hosts.yml playbooks/50-swarm.yml \
  --check --diff
ansible-playbook -i inventories/production/hosts.yml playbooks/50-swarm.yml \
  --diff
```

Проверка:

```bash
ssh overtone-manager-1 docker node ls
```

Если внутреннего SSH alias ещё нет, выполните команду с Mac через `ssh -J`:

```bash
ssh -J overtone-bastion \
  -i ~/.ssh/overtone-infra/keys/overtone-production \
  overtone@CHANGE_ME_MANAGER_1_PRIVATE_IP docker node ls
```

## 9. HAProxy

Конфигурация проксирует TCP 80/443 на приватные адреса обоих workers. TLS здесь
не завершается. Пока на workers ничего не слушает, HAProxy будет запущен, но
backend health checks будут показывать `DOWN` — это ожидаемо.

На чистом сервере полноценный `--check` может остановиться на проверке конфига,
потому что бинарник HAProxy ещё не установлен. Поэтому первый реальный запуск
всё равно ограничивается единственным сервером:

```bash
ansible-playbook -i inventories/production/hosts.yml playbooks/60-haproxy.yml \
  --limit haproxy --diff
```

Проверка:

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg
systemctl status haproxy --no-pager
```

## 10. Итоговая read-only проверка

```bash
ansible-playbook -i inventories/production/hosts.yml playbooks/90-verify.yml
```

Перед любым реальным запуском всегда проверяйте `--limit`, выбранный inventory и
список hosts в выводе Ansible.
