# LTS security remediation cascade (v1.32.13-lts.2 … lts.5)

Staged CVE remediation for the six Kubernetes components, driven by real scanner
data and **reachability analysis**, not raw scanner counts.

## Method

| Tool | Role |
|---|---|
| **grype** | Inventory (version-matching). Over-reports: flags every CVE whose fixed version is newer than what's vendored, regardless of whether the code is used. |
| **govulncheck** (`-mode=binary`) | **Reachability**. Reports only CVEs whose vulnerable *symbols* are actually linked into our binaries. This is the exploitability signal. |

Baseline (`v1.32.13` / go1.24.13): grype found **200 unique** findings; govulncheck
found only **25 reachable**. ~88% of grype's findings are not exploitable in our binaries.

## Remediation, grouped by fix mechanism (one mechanism per release)

| Release | Group | Change | Reachable CVEs cleared |
|---|---|---|---|
| **lts.2** | Go stdlib | `.go-version` 1.24.13 → **1.25.11** | 18 (crypto/x509 & net & mime & net/mail & net/textproto DoS, os.Root, html/template) |
| **lts.3** | golang.org/x/net | → **0.55.0** (+ transitive x/crypto 0.51, x/sys 0.45) | 3 (HTTP/2 loop CVE-2026-33814, punycode CVE-2026-39821, CVE-2025-22872) |
| **lts.4** | vendored modules | grpc 1.65→**1.79.3**, spdystream 0.5.0→**0.5.1** | 2 (gRPC auth-bypass CVE-2026-33186, spdystream DoS CVE-2026-35469) |
| **lts.5** | base image | kube-proxy `distroless-iptables` v0.6.7 → **v0.7.15** | OS-package CVEs (base layer) |

Each release was gated by **unit + widened-unit + integration (real apiserver+etcd) +
compile**, then artifact **smoke** (image runs, apiserver serves, debs install), then
re-scanned to confirm the targeted CVEs were cleared.

## Result — govulncheck reachable, before → after

| Component | grype 200-base → lts.5 | **reachable → lts.5** |
|---|---|---|
| kube-apiserver | 91 → 18 | 24 → **2** |
| kube-controller-manager | 95 → 22 | 22 → **2** |
| kube-scheduler | 88 → 16 | 20 → **1** |
| kube-proxy | 242 → 107 | 21 → **2** |
| kubelet | 95 → 22 | 24 → **2** |
| kubectl | 64 → 1 | 16 → **0** |

**Union reachable across all components: 25 → 2.** The 2 remaining are documented in
[`vex.openvex.json`](./vex.openvex.json):

- **CVE-2026-24051** (otel/sdk PATH hijack) — *affected, deferred*. The fix (otel ≥1.40)
  pulls `filepath-securejoin` 0.6.0, which breaks vendored runc 1.2.1. Exploitation needs
  non-default tracing **and** attacker-controlled PATH. Fixed when the line moves to a
  runc compatible with the new securejoin API.
- **CVE-2025-52881** (selinux/runc container escape) — *not affected*. The escape happens
  in the node-runtime runc that creates containers, not our vendored copy.

## Residual scanner findings (not reachable)

The remaining grype findings are explained, not chased (per the "reachable-only + VEX"
policy):

- **Go-module non-reachable** (x/crypto 0.52 criticals, vendored runc GHSAs, otel/otelrestful):
  govulncheck confirms no reachable symbol → `not_affected: vulnerable_code_not_in_execute_path`.
  Bumping these (e.g. x/crypto→0.52, runc→1.3) would be large, risky changes for code that
  isn't executed.
- **OS packages** (kube-proxy's `distroless-iptables` base, ~107): inherited from the base
  image; the base is bumped to the version k8s 1.32.13 itself pins (v0.7.15). Remaining
  entries are Debian packages without an available fixed version.

## Testing approach (vs. upstream)

Upstream Kubernetes treats **unit + integration** as release-blocking and runs
conformance/e2e in periodic/release jobs. This LTS line mirrors that:

- **Per change (PR gate):** unit ×6 + `unit-core` (net/tls/x509/serialization trees) +
  **integration** (`test/integration` configmap/secrets/serviceaccount against real
  apiserver+etcd) + compile.
- **Per release (pre-publish):** artifact **smoke** — each image runs, kube-apiserver
  serves `/version` against etcd, kubelet/kubectl debs install.
- Full e2e / node-e2e / conformance fleet: out of per-patch scope (run pre-bundle).

> Gotcha baked into CI: the integration job drops `-trimpath` (the in-process apiserver
> test server needs source-relative paths); local pre-checks must use `GOOS=linux`
> (darwin skips runc's Linux-only code).
