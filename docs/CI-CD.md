# CI/CD responsibility and secrets

The Ansible repository CI validates Ansible only. It never applies playbooks or
deploys production. Application images and Swarm stack deployment remain in
`overtone-infra`.

## Image and deployment flow

```text
Git push
-> GitHub Actions checks
-> independent Docker builds
-> Docker Hub push with build/push token
-> immutable tags/digests
-> SSH through bastion to manager
-> Docker Hub login with pull-only production token
-> /opt/overtone-infra/scripts/deploy.sh
-> docker stack deploy --with-registry-auth
-> smoke test
-> component rollback when required
```

Ansible never builds or publishes application images and never creates a second
stack/deploy implementation.

## GitHub values

Repository variable:

- `DOCKERHUB_USERNAME`.

Repository secrets used for build/push:

- `DOCKERHUB_TOKEN` with publish permission;
- `OVERTONE_REPO_TOKEN` if the application repository is private.

Protected `production` environment secrets/variables:

- a separate pull-only `DOCKERHUB_TOKEN`;
- `SWARM_ENV_FILE`;
- `DEPLOY_SSH_KEY` containing only the CI deploy private key;
- `DEPLOY_KNOWN_HOSTS` containing verified pinned bastion and manager keys;
- bastion address and user;
- manager private address and user;
- `DOCKERHUB_USERNAME` as a variable.

Never use `StrictHostKeyChecking=no`. Obtain host keys, verify their fingerprints
through the provider console/out-of-band channel, then pin both hops.

## Current integration boundary

The existing `overtone-infra` release workflow currently SSHes directly to one
`DEPLOY_HOST`; it does not yet construct a ProxyJump configuration. That workflow
must be updated in the `overtone-infra` repository under a separate authorized
change before cloud deployment through bastion can work.

`playbooks/80-deploy-host.yml` now manages the approved permanent CI identity on
bastion and manager. On manager it can run arbitrary Docker commands and is
therefore root-equivalent even without sudo. It also owns
`/opt/overtone-infra`. On bastion its public key is restricted to TCP forwarding
to the selected manager SSH endpoint. The playbook has not been applied by this
repository change; follow `docs/OPERATIONS.md` host by host.

No private CI key, Docker Hub token or production `.env` belongs in this
repository or its example inventory.
