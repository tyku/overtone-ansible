# Container access to the existing inference tunnel

An SSH reverse listener bound to `127.0.0.1` is reachable from the worker host,
but not from a container's separate network namespace. The Ansible role does not
change the SSH tunnel or set `GatewayPorts`. When explicitly enabled, it creates
a small systemd-managed `socat` proxy:

```text
container -> worker private IP:endpoint port
          -> worker loopback:SSH listener port
          -> existing SSH reverse tunnel -> inference/GPU machine
```

## Required observation before enabling

On each worker, record without changing anything:

```bash
sudo ss -lntp
ip -br address
ip route
sudo ufw status verbose
sudo iptables -S INPUT
sudo iptables -S FORWARD
sudo iptables -S DOCKER-USER
docker network ls
docker network inspect bridge
```

Confirm the listener's actual bind address/port and determine which source
address reaches the host when a container connects to its private IP. Do not
assume `172.17.0.0/16`, and do not assume `DOCKER-USER` sees container-to-host
traffic.

## Per-worker listeners

Put host-specific values in ignored `hosts.yml`. Example for each worker:

```yaml
inference_tunnel_networking_enabled: true
inference_tunnel_ssh_listener_address: 127.0.0.1
inference_tunnel_ssh_listener_port: 50052
inference_tunnel_endpoint_address: "PRIVATE_WORKER_IP"
inference_tunnel_endpoint_port: 15051
inference_tunnel_manage_ufw: true
inference_tunnel_allowed_sources:
  - OBSERVED_DOCKER_OR_PRIVATE_CIDR
inference_tunnel_firewall_interface: ""
inference_tunnel_container_probe_enabled: true
inference_tunnel_probe_image: docker.io/library/alpine:PINNED_VERSION
inference_tunnel_probe_network: bridge
```

For one shared endpoint, enable the role only on the selected worker and point
the application at that worker private IP. For one listener per worker, enable
both hosts with the same endpoint port. `INFERENCE_GRPC_ADDRESS` remains an
`overtone-infra` setting.

## Apply and verify

The existing SSH tunnel/local machine must be active for the preflight check:

```bash
ansible-playbook -i inventories/production/hosts.yml \
  playbooks/55-tunnel-networking.yml --limit worker-1 --check --diff

ansible-playbook -i inventories/production/hosts.yml \
  playbooks/55-tunnel-networking.yml --limit worker-1
```

The role verifies the loopback listener, binds only the worker private address,
adds only explicit optional UFW sources, checks the host listener and can run a
temporary `docker run --rm` probe with a versioned image.

After the application overlay exists, run a separate check from the actual
application container/service. Also test from an external network that the
tunnel port is not reachable through the public worker address. Those two path
tests cannot be proven by a pre-deployment host-only playbook.

An inactive tunnel fails with a clear diagnostic and never rewrites sshd,
authorized keys or the external tunnel process.
