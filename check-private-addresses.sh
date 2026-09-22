#!/usr/bin/env bash

set -u

hosts=(
  "overtone-haproxy"
  "overtone-manager"
  "overtone-worker-1"
  "overtone-worker-2"
  "overtone-bastion"
)

commands=(
  "ip -br address"
  "ip route"
  "ip neigh show"
)

ssh_options=(
  -T
  -n
  -o BatchMode=yes
  -o ConnectTimeout=10
)

exit_code=0

for host in "${hosts[@]}"; do
  printf '\n===== %s =====\n' "$host"

  for command in "${commands[@]}"; do
    printf '\n--- %s ---\n' "$command"

    ssh "${ssh_options[@]}" "$host" "$command"
    status=$?

    if (( status == 255 )); then
      printf 'ERROR: не удалось подключиться к %s\n' "$host" >&2
      exit_code=1
      break
    elif (( status != 0 )); then
      printf 'ERROR: команда завершилась с кодом %d на %s: %s\n' \
        "$status" "$host" "$command" >&2
      exit_code=1
    fi
  done
done

exit "$exit_code"
