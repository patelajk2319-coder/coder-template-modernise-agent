# coder-template-modernise-agent

Coder workspace template for interactively modernizing
[coder-demo-modernise-flask](https://github.com/patelajk2319-coder/coder-demo-modernise-flask)
(Flask → FastAPI) with Claude Code, inside a network-locked, audit-logged
workspace. Built for the regulated-environment / compliance pitch: a developer
drives the migration, reviews and commits every change — no autonomous
headless agent — while every model call is routed through Coder's AI Bridge
and centrally logged.

## Human-driven, not autonomous

This deliberately does **not** use a `coder_ai_task` resource. Modernization
work involves judgment calls (is this dead code, does this silently change
behavior) where unsupervised full autonomy is the riskier choice for a
compliance audience — a developer works interactively via code-server/terminal
and reviews everything before committing.

## AI Bridge routing

The workspace's `ANTHROPIC_BASE_URL`/`ANTHROPIC_AUTH_TOKEN` point Claude Code
at `coder-demo-eks`'s AI Bridge, which routes to Amazon Bedrock via that
repo's own IRSA role — no Anthropic key of any kind ever reaches the
workspace, and every call is centrally logged. **Requires `coder-demo-eks`
running Coder ≥ v2.36.5** — earlier versions don't know `claude-sonnet-5`
needs the newer "adaptive" thinking schema and let requests through
unconverted, which Bedrock then rejects.

The Coder API token used for AI Bridge auth is baked in at template-push time
(one Terraform variable, same value for every workspace built from a given
template version) — not a per-developer parameter. Every workspace on that
version shares one AI Bridge identity; fine for a single-operator demo, but
logs won't distinguish between developers if this is ever used by more than
one person.

## Branching

Each workspace creates/checks out `modernize/<workspace-name>` on first boot
and pushes it immediately — modernization work never happens on `main`.
`main` on `coder-demo-modernise-flask` has GitHub branch protection (no direct
pushes, PR + review required) as a backstop.

## Known gap: no domain-level egress filtering

The workspace's `NetworkPolicy` restricts egress by port (DNS/53, HTTP/80,
HTTPS/443) only — this cluster's VPC CNI enforces `NetworkPolicy` natively but
has no Calico/Cilium L7 filtering, so there's no way yet to restrict egress to
specific domains (e.g. only `api.anthropic.com` and `github.com`). Documented,
not solved here.

## Versioning

`task template` pushes a new Coder template revision named after whatever's
currently in `VERSION`, so bump it before pushing a new revision (pushing the
same version name twice fails — Coder requires unique template version
names).

`task template` applies `terraform/coderd` (the `coderd` Terraform provider,
not the `coder` CLI) — a separate Terraform root from
`templates/modernize-flask-workspace`, which is the workspace template's own
Terraform, executed by the provisioner on each build. `task workspace` and
`task logs` still go through the `coder` CLI directly — there's no Terraform
resource for provisioning an ephemeral workspace or streaming its logs.

## Prerequisites

- `coder-demo-eks` deployed (`task infra` → `task coder` → `task init`),
  running Coder ≥ v2.36.5 (see [AI Bridge routing](#ai-bridge-routing)), with
  its port-forward running (`task port-forward` in that repo) — Coder's
  LoadBalancer is internal-only, so this repo talks to it over
  `http://localhost:8080`.
- `coder`, `terraform`, `go-task`, `shellcheck` installed locally.
- `CODER_API_TOKEN` in `.env` — a long-lived API token minted on `coder-demo-eks`
  via `task init`, handed to this repo the same way `CODER_ADMIN_PASSWORD` is.
- GitHub external auth configured on `coder-demo-eks` (`CODER_EXTERNAL_AUTH_0_*`,
  see that repo's README) — each developer authorizes their own GitHub identity
  from the Coder dashboard on first workspace build; no PAT is baked into this
  template. `scope=repo` covers clone + push to the modernization branch.

## How it works

Each workspace is a single Kubernetes pod (no Docker-in-Docker — this isn't a
container-build demo), non-root, with a persistent `/home/coder` on a `gp3`
EBS-backed PVC, in a per-workspace namespace (`coder-ws-<owner>-<workspace>`)
whose egress `NetworkPolicy` only allows DNS, HTTP and HTTPS.

On first boot, the startup script clones `coder-demo-modernise-flask`, creates
and pushes `modernize/<workspace-name>`, installs Claude Code CLI (via nvm +
npm) and a Python venv, and leaves the developer to do the actual migration
work interactively in code-server or a terminal.

## Quick start

```bash
cp .env.example .env   # fill in CODER_ADMIN_PASSWORD, CODER_API_TOKEN, template metadata

task template            # push the template
task workspace           # provision a workspace
task logs                # tail the workspace's startup logs
```

## Commands

| Command          | Description                                                    |
|------------------|-------------------------------------------------------------------|
| `task template`  | Push/update the template via Terraform, versioned from `VERSION`   |
| `task release`   | Tag and push the current `VERSION` as a git release (`vX.Y.Z`)      |
| `task workspace` | Provision a workspace (`NAME=<name>` to override the name)          |
| `task logs`      | Stream startup logs from the active workspace                       |
| `task validate`  | `terraform fmt`/`validate` + `shellcheck`                            |
