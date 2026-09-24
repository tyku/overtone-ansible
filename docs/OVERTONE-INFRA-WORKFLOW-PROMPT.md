# Prompt for updating overtone-infra deployment workflows

Use the following prompt in a separate Codex task whose workspace is
`/Users/artemkud/dev/overtone-infra`.

```text
Приведи production deploy и rollback workflow в репозитории
/Users/artemkud/dev/overtone-infra к подключению к Docker Swarm manager через
bastion. Работай только в этом репозитории; overtone-ansible не изменяй и ничего
не запускай на production.

Сначала изучи текущие .github/workflows/release.yml,
.github/workflows/rollback.yml, scripts/deploy.sh, README и
docs/CLOUD-RELEASE.md. Сохрани существующую схему build/push, immutable
tags/digests, smoke checks, component rollback и
docker stack deploy --with-registry-auth. Не создавай вторую реализацию deploy.

Обнови release и rollback так, чтобы rsync/ssh шли через bastion к приватному
адресу manager под пользователем overtone_deploy. Используй protected GitHub
Environment `production` и следующие значения:

- BASTION_HOST — variable или secret с публичным адресом bastion;
- BASTION_USER — variable, ожидаемо overtone_deploy;
- MANAGER_PRIVATE_HOST — variable/secret с приватным адресом manager;
- DEPLOY_USER — variable, ожидаемо overtone_deploy;
- DEPLOY_SSH_KEY — secret с отдельным приватным CI-ключом;
- DEPLOY_KNOWN_HOSTS — secret с заранее проверенными и pinned host keys обоих
  хопов;
- DOCKERHUB_USERNAME — variable;
- production-scoped DOCKERHUB_TOKEN — отдельный pull-only secret;
- SWARM_ENV_FILE — production secret;
- существующий OVERTONE_REPO_TOKEN оставь только там, где он нужен сборке.

Build/push credential и production pull credential должны оставаться разными.
Не переименовывай существующие build secrets без необходимости.

В job создай ~/.ssh с mode 0700, приватный ключ и known_hosts с mode 0600.
Создай ~/.ssh/config с двумя alias примерно такого вида (подставляя GitHub
values, без вывода секретов в лог):

Host overtone-bastion-ci
  HostName <BASTION_HOST>
  User <BASTION_USER>
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile ~/.ssh/known_hosts
  StrictHostKeyChecking yes
  BatchMode yes

Host overtone-manager-ci
  HostName <MANAGER_PRIVATE_HOST>
  User <DEPLOY_USER>
  ProxyJump overtone-bastion-ci
  IdentityFile ~/.ssh/id_ed25519
  IdentitiesOnly yes
  UserKnownHostsFile ~/.ssh/known_hosts
  StrictHostKeyChecking yes
  BatchMode yes

DEPLOY_KNOWN_HOSTS должен содержать out-of-band проверенные записи для точных
HostName обоих хопов: публичного адреса bastion и приватного адреса manager.
Не используй StrictHostKeyChecking=no и не делай ssh-keyscan/TOFU внутри
workflow.

Переведи rsync и удалённые команды на alias overtone-manager-ci. Сохрани
текущие excludes и целевой каталог /opt/overtone-infra/. Если остаётся
rsync --delete, проверь, что его target не может выйти за пределы этого каталога.

Создавай production .env с mode 0600 до записи содержимого, не печатай его и
не передавай как аргумент командной строки. Docker Hub login на manager выполняй
через --password-stdin и временный DOCKER_CONFIG, удаляемый trap при выходе,
чтобы pull token не остался в ~/.docker/config.json. Корректно обработай shell
quoting: секреты не должны появиться в workflow log, process arguments или
репозитории.

Не меняй триггер на автоматический production deploy: сохрани текущий ручной
gate/workflow_dispatch/deploy boolean и protected production environment.
Приватные ключи, токены, known_hosts и .env не добавляй в git.

Обнови README и docs/CLOUD-RELEASE.md: перечисли требуемые variables/secrets,
отдельность build/push и pull-only токенов, способ out-of-band проверки host-key
fingerprints и новую схему ProxyJump.

После изменений выполни доступные локальные статические проверки workflow и
shell-скриптов, но не подключайся к серверам и не запускай deployment. В финале
дай: краткий аудит найденного, список изменённых файлов, точный список GitHub
values для настройки, результаты проверок и оставшиеся ручные шаги.
```
