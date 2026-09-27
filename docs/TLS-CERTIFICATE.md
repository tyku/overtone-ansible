# Сертификат priemo.tech и admin.priemo.tech

DNS админского имени не обязан указывать на публичный сервер. Для обоих имён
используется DNS-01: Ansible локально на Mac запрашивает у Let's Encrypt
одноразовые TXT-значения, а оператор добавляет их у своего DNS-провайдера.
API-токен DNS-провайдера не нужен и в репозитории не хранится. Каждый выпуск
или продление сертификата требует повторить ручной DNS-шаг.

1. На Mac из каталога `overtone-ansible` установите pinned collections:

   ```bash
   ansible-galaxy collection install -r requirements.yml -p .collections
   ```

2. После ознакомления с условиями Let's Encrypt запустите локальный playbook.
   Подставьте собственный email для уведомлений об истечении сертификата:

   ```bash
   ansible-playbook -i localhost, playbooks/75-issue-tls.yml \
     -e tls_contact_email=you@example.com \
     -e tls_acme_terms_agreed=true -e tls_issue_confirmed=true
   ```

   Команда обращается к Let's Encrypt **с Mac**, но не подключается к VPS.
   Ключи и сертификат сохраняются только в игнорируемой Git директории
   `.local/priemo-tls/`; не копируйте их в Git.

3. Playbook покажет точные DNS TXT имена и значения. У DNS-провайдера добавьте
   **все** показанные значения, обычно для:

   ```text
   _acme-challenge.priemo.tech
   _acme-challenge.admin.priemo.tech
   ```

   В панели, которая сама добавляет суффикс зоны `priemo.tech`, имена могут
   вводиться как `_acme-challenge` и `_acme-challenge.admin`. Не угадывайте TXT
   значения заранее: используйте только выведенные playbook’ом. Если панель
   позволяет, поставьте низкий TTL (например 60–300 секунд). Дождитесь, когда
   оба ответа видны в публичном DNS:

   ```bash
   dig +short TXT _acme-challenge.priemo.tech
   dig +short TXT _acme-challenge.admin.priemo.tech
   ```

   Сравните ответы с показанными значениями и только тогда нажмите Enter в
   ожидающем playbook’е. После успешного выпуска временные TXT можно удалить.
   Публичная A/AAAA-запись для `admin.priemo.tech` не требуется.

4. Playbook проверит оба имени и соответствие приватного ключа сертификату.
   Затем оператор может выполнить предварительную проверку сертификата и
   наличия deploy-пользователя на manager без копирования файлов:

   ```bash
   ansible-playbook -i inventories/production/hosts.yml \
     playbooks/76-stage-tls.yml --limit manager-1 \
     -e tls_stage_confirmed=true --check
   ```

   После просмотра playbook’а и проверки повторите без `--check`. Это
   **соединяется с VPS**;
   выполнять должен только оператор. Playbook кладёт файлы в
   `/etc/overtone/tls/` с ограниченными правами, вне каталога rsync-деплоя.

5. В `/opt/overtone-infra/.env` на manager задайте:

   ```text
   TLS_CERT_FILE=/etc/overtone/tls/fullchain.pem
   TLS_KEY_FILE=/etc/overtone/tls/privkey.pem
   ```

   Если текущие Docker Secrets уже существуют, задайте **новые, ещё не
   использованные** имена `TLS_CERT_SECRET` и `TLS_KEY_SECRET`. Docker Secrets
   неизменяемы, а `scripts/deploy.sh` создаёт только отсутствующие секреты.
   Затем оператор запускает обычный deploy; Ansible сам Docker Stack не меняет.

Сохраните защищённую резервную копию `.local/priemo-tls/`, особенно ключей.
Проверяйте срок действия заранее и повторяйте процедуру до истечения
сертификата. Это ручное продление, не фоновая автоматизация.
