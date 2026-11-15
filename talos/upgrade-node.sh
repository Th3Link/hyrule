#!/usr/bin/env bash
# Upgrade Talos on one node, taking care of the VMs and Longhorn.
#
#   talos/upgrade-node.sh <node> [installer-image]
#
# The installer image defaults to the one in talos/nodes/<node>.yaml
# (bumped by Renovate). Steps:
#   1. refuse to start while any Longhorn volume is degraded
#   2. stop the VMs running on the node (their disk has a single replica there,
#      so Longhorn would block the drain)
#   3. node-drain-policy -> allow-if-replica-is-stopped
#   4. talosctl upgrade (drain, install, reboot, uncordon)
#   5. restore node-drain-policy, uncordon, start the VMs again (also on failure)
#   6. wait until Longhorn is ready on the node and no volume is degraded
set -euo pipefail

node=${1:?usage: $0 <node> [installer-image]}
dir=$(cd "$(dirname "$0")" && pwd)
image=${2:-$(grep -oE 'factory\.talos\.dev/[^[:space:]]+-installer/[^[:space:]]+' "$dir/nodes/$node.yaml" | head -1)}
[[ -n $image ]] || { echo "no installer image found in $dir/nodes/$node.yaml" >&2; exit 1; }

ip=$(kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' | awk '{print $1}')
[[ -n $ip ]] || { echo "node $node not found" >&2; exit 1; }

degraded() {
  kubectl -n longhorn get volumes.longhorn.io \
    -o jsonpath='{range .items[?(@.status.robustness=="degraded")]}{.status.kubernetesStatus.pvcName}{"\n"}{end}'
}
wait_healthy() {
  echo "waiting for Longhorn rebuilds ..."
  while [[ -n $(degraded) ]]; do sleep 20; done
}
set_policy() {
  kubectl -n longhorn patch settings.longhorn.io node-drain-policy --type merge -p "{\"value\":\"$1\"}" >/dev/null
}

current=$(talosctl -n "$ip" version --short 2>/dev/null | awk '/Tag:/{t=$2} END{print t}' || true)
echo "node:    $node ($ip), running $current"
echo "image:   $image"

if [[ -n $(degraded) ]]; then
  echo "degraded volumes, wait for the rebuilds first:" >&2
  degraded >&2
  exit 1
fi

mapfile -t vms < <(kubectl get vmi -A -l "kubevirt.io/nodeName=$node" \
  -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')
echo "VMs:     ${vms[*]:-none}"
read -rp "continue? [y/N] " ok
[[ $ok == y ]] || exit 1

cleanup() {
  set +e
  echo "restoring node-drain-policy, uncordoning $node, starting VMs ..."
  set_policy block-if-contains-last-replica
  kubectl uncordon "$node" >/dev/null
  for vm in "${vms[@]}"; do virtctl -n "${vm%/*}" start "${vm#*/}"; done
}
trap cleanup EXIT

for vm in "${vms[@]}"; do
  virtctl -n "${vm%/*}" stop "${vm#*/}"
done
for vm in "${vms[@]}"; do
  while kubectl -n "${vm%/*}" get pod -l "vm.kubevirt.io/name=${vm#*/}" -o name | grep -q .; do sleep 3; done
done

set_policy allow-if-replica-is-stopped
talosctl -n "$ip" upgrade --image "$image" --wait

cleanup
trap - EXIT

echo "waiting for Longhorn on $node ..."
until [[ $(kubectl -n longhorn get nodes.longhorn.io "$node" \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') == True ]]; do sleep 5; done
wait_healthy
talosctl -n "$ip" version --short | awk '/Tag:/{t=$2} END{print "done: '"$node"' now on " t}'
