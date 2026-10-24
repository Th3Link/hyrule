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
- **Talos** (`talos` group), one node at a time, worker first, wait until the
  node is Ready and etcd is healthy before the next one:
  `talosctl -n <ip> upgrade --image factory.talos.dev/metal-installer/98c912e25a452279d00bd5f060b0b3f6677ee1546f391928bab5ed1e5bd90bd7:<version> --wait`

Each VM in `vms/` has its disk only on its own node, so it is down while that
node reboots and comes back afterwards.
