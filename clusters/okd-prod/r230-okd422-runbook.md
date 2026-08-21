# r230 -> OKD 4.22 runbook

**This branch must not be merged as-is.** Argo runs this repo with
`automated: {prune: true, selfHeal: true}`, so merging is itself the
destructive act — Argo prunes the ClusterDeployment and Hive begins
deprovisioning. Nobody has to run a delete command.

## What is at stake

r230 is currently **installed, healthy and Available**, running OCP **4.19.42**
across four nodes (dell1/2/3 as control-plane+worker, dell5 as worker), with
real data on it:

| PVC | Size |
| --- | --- |
| `openshift-operators/example-registry-quay-postgres-13` | 50Gi |
| `openshift-operators/example-registry-clair-postgres-15` | 50Gi |
| `openshift-storage/db-noobaa-db-pg-0` | 50Gi |
| `openshift-storage/ocs-deviceset-0/1/2-data-*` | 3 x 500Gi |
| clair indexer layer storage (x2) | 2 x 20Gi |

Roughly **1.7TB across 8 bound PVCs**, including a Quay registry with its
Postgres, a three-device Ceph/ODF cluster, its own ArgoCD instance (app
`r230-cluster`) and cert-manager. All of it is destroyed by this procedure.

There is **no OCP -> OKD upgrade path** — different payload entirely. This is a
destroy-and-rebuild.

## BMC inventory

Credentials are `root` / `calvin` (iDRAC defaults), stored base64 in
`bmo-hosts.yaml` as `cm9vdA==` / `Y2Fsdmlu`.

| host | BMC (iDRAC) | boot MAC | node IP |
| --- | --- | --- | --- |
| `dell1-r230` | 192.168.100.1 | `50:9A:4C:92:EF:6D` | 192.168.101.11 |
| `dell2-r230` | 192.168.100.2 | `50:9A:4C:98:43:38` | 192.168.101.12 |
| `dell3-r230` | 192.168.100.3 | `6C:2B:59:7A:5F:92` | 192.168.101.13 |
| `dell5-r230` | 192.168.100.5 | `50:9A:4C:97:24:0A` | 192.168.101.15 |

Node IPs are static, set via the `NMStateConfig` objects in
`r230-cluster.yaml`, matched to the host by MAC.

These iDRACs speak Redfish virtual media (`idrac-virtualmedia://`) and are
**not** licence-gated — unlike soup's Supermicro BMC, which refuses Redfish
with `OemLicenseNotPassed` / "SUM DCMS OOB needed". So once Ironic works, these
four can genuinely be driven automatically.

## Blockers to clear first

1. **Back up the data.** Quay registry + its Postgres, and anything on the Ceph
   cluster. Nothing here is recoverable afterwards.

2. **Fix Ironic.** It is crash-looping on the `COREOS_VERSION=9` vs SCOS-10 bug
   — `copy-metal` defaults to CoreOS 9 and looks for `/coreos/coreos-stream.json`,
   but the OKD 5 payload only ships `coreos10-stream.json`. Verified fix:

   ```bash
   oc patch clusterversion version --type=merge -p '{"spec":{"overrides":[{"group":"apps","kind":"Deployment","name":"cluster-baremetal-operator","namespace":"openshift-machine-api","unmanaged":true}]}}'
   oc scale deploy/cluster-baremetal-operator -n openshift-machine-api --replicas=0
   for d in metal3 metal3-image-customization; do
     oc patch deploy $d -n openshift-machine-api \
       -p '{"spec":{"template":{"spec":{"initContainers":[{"name":"machine-os-images","env":[{"name":"COREOS_VERSION","value":"10"}]}]}}}}'
   done
   ```

   Without this, BMO cannot drive the iDRACs and all four nodes must be booted
   by hand from the discovery ISO.

3. **Prove OKD 4.22 on soup first.** soup is empty and costs nothing if the
   install fails; r230 costs 1.7TB.

## Manual change still required

`bmo-hosts.yaml` needs `externallyProvisioned: true` -> `false` on all four
hosts. That is required for BMO to manage boot (it will not attach virtual
media to a host it considers externally provisioned).

It is deliberately **not** done in this branch, because applying it to the
running cluster is independently destructive: it tells BMO these installed
nodes are its to provision, and it may deprovision and clean them regardless of
what the ClusterDeployment is doing. Argo applies by sync-wave and cannot
guarantee it lands only after teardown.

## Ordered procedure

1. Back up Quay/Postgres/Ceph data. Verify the backups restore.
2. Fix Ironic (above); confirm `metal3` reaches `3/3 Running`.
3. Detach from ACM: `oc delete managedcluster r230`
4. Delete the cluster: `oc delete clusterdeployment r230 -n r230`
   — this deprovisions and wipes the nodes.
5. Wait for deprovision to finish and the namespace to settle.
6. Flip `externallyProvisioned` to `false` in `bmo-hosts.yaml`.
7. Merge this branch so Argo applies the OKD 4.22 `imageSetRef`.
8. Watch: `oc get agentclusterinstall r230 -n r230 -w`, then approve agents as
   they register.
9. Restore data onto the rebuilt cluster.

## What this branch actually changes

- `r230-cluster.yaml`: `imageSetRef` `img4.19.28-x86-64-appsub` ->
  `okd-4.22.0-scos-8`, plus a warning header. The imageset itself is already in
  `main` (added by `soup-cluster.yaml`).
- `r230-okd422-runbook.md`: this file.

`imageSetRef` is immutable, so applying it requires deleting both the
AgentClusterInstall and the ClusterDeployment — assisted-service keeps the old
version registered in its database until the ClusterDeployment goes. This was
confirmed the hard way during soup's rebuild.
