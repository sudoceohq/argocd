# Customized Helm across clusters

`clusters/management` remains the management entry point and is a reusable Helm Application chart. It renders only Longhorn, Crossplane and the Vault provider by default. Subsequent stage flags live in `clusters/<id>/values.yaml`. The management root loads `cluster.yaml`; remote roots load their `values.yaml` followed by `cluster.yaml`. Edit cluster identity/endpoints in `cluster.yaml`, which wins over chart defaults. Upstream customization uses each dependency's original name as its values key; there is no fork of vendor templates or Crossplane wrapper for Helm releases.

OCI's profile is disabled and unprepared. It has its own `pki-oci` intermediate, `kubernetes-oci` authentication mount, `oci-istio-signer` policy/role, and `oci.thriftystack.internal` trust domain. Management retains `pki-management`, `kubernetes-management` and `mgmt.thriftystack.internal`. The root remains generated once inside management Vault. All Vault API resources are reconciled by management Crossplane; certificate controllers and Istio run in each destination cluster. OCI never deploys another root, Vault, Crossplane or management Longhorn through this workload profile. Existing storage/networking in remote clusters must be verified independently.

This uses independent Istio **sidecar** control planes, not a connected ClusterMesh or a single flat Istio mesh. Certificates rotate through each cluster's cert-manager and istio-csr; trust domains have no aliases. Sharing the root does not provide application authorization or prevent a compromised shared CA from impersonating another domain. Inter-cluster service discovery, private gateways, network routing and authorization policies are separate reviewed work. No OCI cluster is provisioned or registered here.

## Activate a remote cluster only after supplying real inputs

1. Provide its actual Kubernetes API URL, API CA, operator context and an Argo-compatible credential delivery/rotation flow. Establish private routing from management Argo to this API. Register the remote cluster out of Git after authorization; verify least-privilege RBAC, credential renewal and revocation. Add only the namespaces/resources Argo should manage. Certificate controllers require cluster-scoped CRDs/RBAC; the administrative project whitelist grants broad cluster resource access, so restrict Git write access and remote credentials accordingly.
2. Establish private routing from remote certificate controllers to management Vault and from Vault to the remote TokenReview API. Supply a reachable TLS Vault URL whose independent listener certificate covers its hostname, and deliver the public listener CA as `istio-system/vault-bootstrap-ca` in that cluster. Do not route via a public unauthenticated service or depend on workload PKI for listener TLS. Customize Vault `apiIngressPeers` with reviewed private `ipBlock`/namespace peers; empty remains the default. NetworkPolicy alone does not establish routing.
3. Establish `kubernetes-oci` on central Vault out of band. Supply the remote API CA and a securely delivered TokenReview identity with `system:auth-delegator`, including a **working reviewer-token rotation mechanism**. Management Vault's local reviewer cannot review OCI tokens. Configure the remote host/CA/reviewer securely, without Git/log payloads. Never put the remote reviewer token into public Helm values. The remote PKI chart omits `AuthBackendConfig`: this external reviewer dependency remains operator-owned until a supported renewable mechanism is selected. Retain the cluster-specific signer role, TokenRequest audience and least-privilege policy.
4. Extend the management provider bootstrap ACL for exact `pki-oci` mount/tune/read endpoints, `pki-oci/issuers/generate/intermediate/internal`, `pki-oci/intermediate/set-signed`, its issuing role, `auth/kubernetes-oci/role/oci-istio-signer` and `sys/policies/acl/oci-istio-signer`. Never grant CA/mount deletion, root leaf issuance or the ability to rewrite the provider's own policy. Keep provider credentials bound to **management**; the remote managed resources reuse `management-vault`. Add future CA generations/mounts to `configuration/vault-provider/values.yaml` protected-name lists before generation.
5. Fill `clusters/oci/cluster.yaml`: destination server, `operatorServer` (same actual remote API), context, reachable `vaultAddress`; set `prepared: true` only after these dependencies work. Leave remote deployment disabled while preparing central PKI. Explicitly add `oci` to management `pkiClusters` after its auth dependency/ACL exists. This creates only central managed resources, including an internal OCI intermediate CSR. On management context, run `ruby ops/pki-handoff.rb sign oci`, review the public declarations, wait for signing/import, then `ruby ops/pki-handoff.rb trust oci` and independently verify the common root fingerprint. Intermediate generation is immutable; never recreate generation objects to repair lost status. See the bootstrap recovery runbook.
6. After central `oci-vault-pki` is Synced/Healthy, enable `cluster.enabled` in the OCI profile and set bootstrap `additional_gitops_clusters.oci` to `{ enabled = true, server = "REAL_TLS_API_URL", namespaces = ["cert-manager", "istio-system", "mesh-test"] }`. Review saved bootstrap plans and Git changes. The OCI root Application remains in management Argo and points to the shared chart with OCI files. Registration credentials are never generated by this setting. Activation/application require separate authorization.
7. Promote OCI's `certificates`, `istio`, `qualification`, and `enrollment` stages sequentially. There is no remote `vault`/`pki` bootstrap stage. Remote promotion reads Application health in **management** and certificate/workload health in **OCI**:

```sh
export THRIFTY_CLUSTER=oci
export KUBE_CONTEXT=YOUR_OCI_CONTEXT
export ARGO_CONTEXT=YOUR_MANAGEMENT_CONTEXT
ruby ops/promote.rb certificates
# Review/publish and wait between each stage.
ruby ops/promote.rb istio
ruby ops/promote.rb qualification
python3 ops/verify-mesh.py --permissive --renewal
ruby ops/promote.rb enrollment
python3 ops/verify-mesh.py
```

For management operations, unset `THRIFTY_CLUSTER` or set it to `management`, and set `KUBE_CONTEXT` to management. Context/API matching is enforced before reads; `cluster.server` can be the in-cluster destination while `operatorServer` is the external VIP. Renewal evidence is stored independently in `.evidence/<id>/renewal.json` and binds the API, pod UID and root fingerprint; proof from another cluster cannot satisfy STRICT promotion. Secrets and raw Envoy secret responses are not persisted.

## Render and upgrade

```sh
helm template management clusters/management -f clusters/management/cluster.yaml
helm template oci clusters/management -f clusters/oci/values.yaml -f clusters/oci/cluster.yaml
# OCI prints no manifests while disabled.
helm template vault charts/vault --namespace vault -f clusters/management/cluster.yaml
CHART_CACHE=/path/to/verified-cache HELM=helm ruby ops/check.rb
```

The offline check renders all local charts, schema-checks provider resources, verifies vendored archives, and renders a synthetic OCI destination to check domain/destination isolation. Synthetic `.invalid` endpoints are test values only. It also checks unchanged Vault service/pod identities and cert-manager RBAC references. This proves no live signing, renewal, failover or restore behavior.

Upgrade the exact dependency version in the wrapper `Chart.yaml`, regenerate `Chart.lock` using Helm's normal dependency workflow, verify the archive against its official index, replace the vendored archive and SHA256 lock, and bump the wrapper version. Bootstrap versions must also match `chart_versions`; OpenTofu rejects mismatched pins. Keep bootstrap `helm_release` addresses and Helm release names unchanged; review saved plans and rendered diffs for replacements, CRD and storage compatibility. Preserve controller status/public signing artifacts before any PKI-controller upgrade. Roll back versions only when supported by the upstream storage/schema format; CA generation is never a rollback target.

Other future clusters can copy the OCI profile with unique IDs, intermediates, auth mounts, policies and trust domains. Configure their per-cluster istiod/istio-csr files consistently; rendering fails if ID/domain values differ. For a separately bootstrapped Talos cluster, use separate local state and a unique Cilium `cluster_identity` numeric ID; this setting does not enable ClusterMesh or provision OCI. Review storage size, replica counts and failure domains rather than assuming the management three-node layout applies everywhere.
