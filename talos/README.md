# Talos machine configs

One file per node in `nodes/`, taken from the live cluster. The secret fields
(`key`, `token`, `secret`, `secretboxEncryptionSecret`, `id`) are encrypted
with sops/age (rule in `/.sops.yaml`); everything else is plain text so
Renovate can bump versions. Flux does **not** apply this folder.

| Node      | IP              | Role          |
|-----------|-----------------|---------------|
| demise    | 192.168.178.234 | control plane |
| ganondorf | 192.168.178.235 | control plane |
| vaati     | 192.168.178.231 | control plane |
| ghirahim  | 192.168.178.236 | worker        |

Decrypting needs the age key: `export SOPS_AGE_KEY_FILE=<path>/age.key`

## Apply a config

```bash
talosctl -n 192.168.178.234 apply-config --dry-run --file <(sops -d talos/nodes/demise.yaml)
talosctl -n 192.168.178.234 apply-config --file <(sops -d talos/nodes/demise.yaml)
```

## Edit a config

```bash
sops talos/nodes/demise.yaml
```

After changing a node live (`talosctl patch mc`, `upgrade-k8s`, ...), pull the
live config back into git:

```bash
talosctl -n 192.168.178.234 get machineconfig v1alpha1 -o jsonpath='{.spec}' \
  | sops --encrypt --filename-override talos/nodes/demise.yaml /dev/stdin > talos/nodes/demise.yaml
```

## Renovate PRs

Merging a Renovate PR only changes the files here. Roll out by hand:

- **Kubernetes** (`kubernetes` group, one minor at a time):
  `talosctl -n 192.168.178.234 upgrade-k8s --to <version>`
- **Talos** (`talos` group), one node at a time, worker first:
  `talos/upgrade-node.sh <node>`

  The script takes the installer image from `nodes/<node>.yaml` and:
  1. refuses to start while a Longhorn volume is degraded,
  2. stops the VMs on the node (their disk has a single replica there, which
     makes Longhorn block the drain),
  3. sets the Longhorn `node-drain-policy` to `allow-if-replica-is-stopped`,
  4. runs `talosctl upgrade` (drain, install, reboot, uncordon),
  5. restores the policy, uncordons and starts the VMs again (also on failure),
  6. waits until every volume has rebuilt.

  Start the next node only after it has finished.
