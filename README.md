# control-repo-test-opus48 — Kubernetes LTS / vanilla build orchestration

Build-orchestration repo for six Kubernetes core components built from a single
upstream tree (`kubernetes/kubernetes`), based on **`v1.32.13`**:

`kube-apiserver` · `kube-controller-manager` · `kube-scheduler` · `kube-proxy`
(container images) and `kubelet` · `kubectl` (`.deb` packages).

It pairs with the source fork [`oleksandr-minakov/k8s-test-opus48`](https://github.com/oleksandr-minakov/k8s-test-opus48)
on matching `release-1.32` branches, following the Mirantis LTS release cascade.

## Dual-source build paths

One `build.sh`, one `build.yaml`, two source paths. The `resolve` job picks the
source repo, the ghcr namespace, and the artifact prefix from `(event, mode)`:

```
                          ┌──────────────────── build.yaml (resolve job) ───────────────────┐
                          │                                                                  │
  Path A · VANILLA        │  mode=vanilla   source=kubernetes/kubernetes@<tag>               │
  manual dispatch    ─────┼─►  ns=upstream-k8s   prefix=upstream-deb                         │
  -F mode=vanilla         │                                                                  │
  -F source_ref=v1.32.13  │                                                ┌──────────────┐  │
                          │                                ── build.sh ──► │ 6 components  │  │
  Path B · LTS            │  mode=lts (default)                            │ ×{image,deb} │  │
  push VERSION on  ───────┼─►  source=oleksandr-minakov/k8s-test-opus48@$(VERSION)           │
  release-1.32            │    ns=lts-k8s-opus48   prefix=lts-deb                 └──────┬───────┘  │
                          └────────────────────────────────────────────────────┼──────────┘
                                                                                 │
            images ─► ghcr.io/oleksandr-minakov/<namespace>/<component>:<tag>    │
            debs   ─► GHA artifact  <prefix>-<component>   (.deb + cosign bundle)─┘
            every artifact: Syft SBOM · Grype SARIF · cosign keyless signature
```

| | Path A — vanilla | Path B — LTS |
|---|---|---|
| Trigger | `workflow_dispatch -F mode=vanilla -F source_ref=<tag>` | push to `release-*` changing `VERSION` (or `-F mode=lts`) |
| Source repo | `kubernetes/kubernetes` | `oleksandr-minakov/k8s-test-opus48` (fork) |
| ghcr namespace | `upstream-k8s` | `lts-k8s-opus48` |
| Deb artifact prefix | `upstream-deb-<component>` | `lts-deb-<component>` |
| Patches | none (reproducible stock rebuild) | Mirantis LTS cherry-picks |

The two namespaces never collide, so stock and patched artifacts for the same
upstream version coexist (`upstream-k8s/...:v1.32.13` vs `lts-k8s-opus48/...:v1.32.13-lts.0`).

## Usage

### Path A — vanilla rebuild of an upstream tag

```bash
gh workflow run build.yaml \
  --repo oleksandr-minakov/control-repo-test-opus48 \
  --ref release-1.32 \
  -F mode=vanilla -F source_ref=v1.32.13
```

### Path B — LTS-patched build (the cascade)

```bash
# on release-1.32 of this repo:
echo 'v1.32.13-lts.1' > VERSION
git commit -am 'chore: bump VERSION to v1.32.13-lts.1' && git push
# build.yaml fires automatically on the VERSION change
```

## Files

| Path | Purpose |
|---|---|
| `VERSION` | Full fork tag (e.g. `v1.32.13-lts.0`). Consulted only in LTS mode. |
| `build.sh` | Source-agnostic builder: `go build` → inline Dockerfile/nfpm config. |
| `.github/workflows/build.yaml` | Dual-source dispatcher (`resolve` + matrix×6 build). |
| `.github/workflows/scan.yaml` | Daily Grype scan of the latest image in **both** namespaces. |

## Supply chain

Each image is signed keyless with cosign (recorded in Rekor) and carries a
CycloneDX attestation; each `.deb` ships a detached `--bundle` side-artifact.
Images are labelled `org.opencontainers.image.source` so the ghcr package links
back to this repo, giving `scan.yaml`'s `GITHUB_TOKEN` read access.
