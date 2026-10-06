# Management GitOps

`clusters/management` is the local Talos management root. Its default applications install Longhorn in wave **-30**, Crossplane in **-20**, and the pinned Vault provider in **-10**. The bootstrap repository installs Argo CD and its administrative AppProject/root Application, including a custom child health check requiring both `Synced` and `Healthy` before subsequent waves start.

Crossplane has the immutable-digest-pinned Upbound Vault provider v4.0.2, with no functions/compositions. It manages supported Vault PKI and signer authentication APIs; Argo CD owns Helm controller/service deployments. The provider uses rotating Kubernetes credentials, not a permanent Vault token. Never adopt the management host VMs or bootstrap state/backup dependencies into a controller running on those VMs.

Infrastructure applications self-heal, disable automated pruning and omit cascading deletion finalizers. Longhorn keeps persistent volumes with a `Retain` reclaim policy. These prevent common accidental deletion paths but do not provide backup recovery.

The repository is public and needs no read credentials. Protect `main` with reviewed changes and restrict write access: changes to the administrative root can grant cluster-wide privileges. Do not commit credentials, cluster registration Secrets or backup keys.

## OCI cluster later

1. Establish routable access from the management cluster to the OCI Kubernetes API and outbound Git/chart registries. Trust the API's CA; do not disable TLS verification.
2. Create a dedicated OCI cluster identity, with permissions constrained to the resources/namespaces Argo CD will manage. Prefer a supported short-lived authentication flow; do not assume workstation OCI CLI credentials are available in Argo CD pods.
3. Deliver its Argo CD cluster-registration Secret through your chosen secret mechanism, label it `argocd.argoproj.io/secret-type: cluster`, and name the cluster `oci`. The API server, CA and authentication details must be real before creating this Secret.
4. Complete `clusters/oci/cluster.yaml` and follow [MULTICLUSTER.md](MULTICLUSTER.md). Only then enable the explicit remote root in bootstrap `additional_gitops_clusters`. Its separate OCI project allows that API and approved namespaces. The management project keeps its local destination scope.
5. Deploy a test application and validate drift correction, credential renewal and access revocation before promoting workloads.

No OCI resources or cluster credentials are created by the current bootstrap, and no placeholder Application points at a nonexistent OCI cluster.

## Longhorn backups

MinIO is intentionally unconfigured. `backupTarget` and `backupTargetCredentialSecret` are empty. Do not interpret replication or local snapshots as off-host backups. Supply an independent MinIO endpoint/bucket and Secret, perform a real backup/restore, and then enable recurring jobs. See the bootstrap repository's `RECOVERY.md` for the starting policy.

## Vault and Istio stages

Only the foundation is enabled initially. `clusters/management/values.yaml` contains inactive stage flags; the shared cluster Helm chart renders Applications only when their stage is promoted:

| Stage | Gate / effect |
|---|---|
| vault | Independent listener TLS + GCP KMS inputs delivered; deploy three retained Raft members |
| pki | Operator initializes/unseals/configures first provider identity; generate internal root + intermediate CSR |
| certificates | Sign/import intermediate through Crossplane, independently verify/pin public root; install cert-manager + namespace-scoped Vault Issuer |
| istio | Issuer Ready; istio-csr first, then Istio base/istiod with built-in CA disabled |
| qualification | Controllers Ready; enroll only disposable mesh-test workloads and observe natural renewal |
| enrollment | Fresh chain/identity/traffic/renewal evidence; enforce STRICT only in mesh-test |

Use the coordinated sibling bootstrap runbooks `bootstrap/VAULT-PKI.md` and `bootstrap/RECOVERY.md` for saved-plan stages, protected prerequisite delivery, encrypted PGP initialization, first-provider auth, backup/recovery and rotation. No Vault initialization hook waits on an uninitialized Vault. The auth bootstrap trust anchor is a deliberate out-of-band operator boundary; subsequent supported PKI/signer configuration is reconciled by Crossplane.

From this GitOps checkout with a protected management `KUBECONFIG`, explicitly select the operator context (its server must match `cluster.operatorServer`):

```sh
export KUBE_CONTEXT=YOUR_MANAGEMENT_CONTEXT
python3 ops/fetch-dependencies.py /path/to/public-cache
CHART_CACHE=/path/to/public-cache HELM=/path/to/helm ruby ops/check.rb
python3 ops/verify-mesh.py --self-test

# After completing each corresponding operator/bootstrap gate:
ruby ops/promote.rb vault
ruby ops/promote.rb pki
# Wait for the individual internal RootCert + IntermediateCertRequest, not the whole app:
ruby ops/pki-handoff.rb sign
# Review/publish public CSR signing/import resources; wait for PKI app readiness:
ruby ops/pki-handoff.rb trust
ruby ops/promote.rb certificates
ruby ops/promote.rb istio
ruby ops/promote.rb qualification
python3 ops/verify-mesh.py --permissive --renewal
ruby ops/promote.rb enrollment
python3 ops/verify-mesh.py
```

**Review and publish each change separately between commands.** Promotions only edit local desired state after read-only live checks; no script pushes or synchronizes Argo. Commands after the self-test are operator procedures and were not run against a cluster during implementation. Never commit private CA keys, tokens, recovery shares, listener keys, seal credentials or `.evidence` payloads. The CSR/root ConfigMap generated by handoff are public artifacts; independently check their fingerprints before publication.

Istio sidecars use `mgmt.thriftystack.internal`, one-hour workload certificates and Vault's management intermediate. Namespace opt-in requires both injection and trust-distribution labels. System/storage/Vault/controller namespaces remain excluded. No ambient, public gateway or OCI registration is configured. Mesh-test explicitly permits privileged admission for sidecar init capabilities; select admission treatment or validate Istio CNI separately before enrolling production namespaces. mTLS authenticates peers; it does not authorize application actions. `examples/workload-authorization.yaml` is an inactive explicit-principal example.

The future OCI cluster requires its own intermediate/auth scope and `oci.thriftystack.internal`, real connectivity/credentials and separately reviewed trust/authorization. A shared root is shared cryptographic trust; distinct names do not create an authorization boundary automatically.

PKI resources are Orphan/Create-Observe protected, mounts deny provider deletion, Vault claims retain data, and a native admission policy rejects protected CA/mount/claim/namespace deletes. Cluster administrators can deliberately remove these guardrails; they are not backups. Extend the protection policy before adding CA generations. MinIO and off-host backups are inactive. Three Vault pods across these VMs remain one physical failure domain.

Offline tests render all custom Helm charts with seven exact vendored upstream dependencies plus management and synthetic OCI profiles; they verify official provider and cert-manager schemas, ordering, issuer wiring, TLS/Raft retention and CA key non-export. Live provider authentication, signing, failover, natural renewal, plaintext rejection and restore remain unverified until those procedures are executed.

Official integration documentation: [istio-csr installation](https://cert-manager.io/docs/usage/istio-csr/installation/), [Vault Issuer](https://cert-manager.io/docs/configuration/vault/), [provider-vault v4.0.2](https://github.com/upbound/provider-vault/tree/v4.0.2).

## Customized Helm and cluster values

Every deployment now uses a local Helm chart: `charts/` wraps pinned upstream services; `configuration/` contains native PKI, provider, policy and qualification templates; `clusters/management/` is the reusable, staged Application chart. Bootstrap separately owns local Cilium, Argo CD and root charts. Dependency archives are vendored and verified against SHA256 locks, and each upstream wrapper has a `Chart.lock`. Dependencies retain their original chart names so service names, RBAC and selectors remain stable.

Customize wrapper defaults under the upstream chart key (for example `vault.server` or `cert-manager-istio-csr.app`). All child Applications load `clusters/<id>/cluster.yaml`; this file can also carry per-cluster overrides under those same keys. Istiod and istio-csr additionally load their explicit cluster override files. `clusters/<id>/values.yaml` holds promotion flags. The shared Application chart uses cluster-prefixed remote Application names, while release names stay stable within each destination cluster. The local management names are preserved.

Read [MULTICLUSTER.md](MULTICLUSTER.md) for remote PKI ownership, private connectivity, context selection and activation. This is independent sidecar mesh control planes with separate intermediate/auth/trust-domain scopes. Cross-cluster discovery, gateways and application authorization require explicit configuration; no implicit trust-domain aliases or public exposure are added.

Helm behavior follows the official [dependency/values format](https://docs.helm.sh/docs/topics/charts/) and [Argo CD Helm value-file resolution](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/).
