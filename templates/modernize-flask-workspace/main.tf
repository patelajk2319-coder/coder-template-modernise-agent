terraform {
  required_version = ">= 1.5.0"

  required_providers {
    coder = {
      source  = "coder/coder"
      version = "~> 2.1"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }
}

# ── Workspace parameters ───────────────────────────────────────────────────────

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# Each developer authorizes their own GitHub identity once via the dashboard —
# no shared PAT baked into the template. Requires CODER_EXTERNAL_AUTH_0_ID=github
# configured on the control plane (coder-demo-eks/terraform/coder).
data "coder_external_auth" "github" {
  id = "github"
}

# AI Bridge auth — routes this workspace's Claude Code CLI through coder-demo-eks's
# AI Bridge instead of calling Anthropic directly, so the real Anthropic key never
# reaches the workspace and every model call is centrally logged. Supplied at
# template-push time via terraform/coderd's tf_vars, not a per-workspace parameter —
# every workspace built from a given template version shares one AI Bridge identity.
variable "coder_api_token" {
  description = "Coder API token used as the (fake) Anthropic API key for AI Bridge routing"
  type        = string
  sensitive   = true
}

data "coder_parameter" "repo_url" {
  name         = "repo_url"
  display_name = "Git Repository"
  description  = "Repository to clone and modernize on workspace start"
  default      = "https://github.com/patelajk2319-coder/coder-demo-modernise-flask"
  type         = "string"
  mutable      = true
}

data "coder_parameter" "instance_size" {
  name         = "instance_size"
  display_name = "Workspace Size"
  description  = "Sizes the workspace container."
  default      = "medium"
  type         = "string"
  mutable      = false

  option {
    name  = "Small  (1 CPU / 2 GB)"
    value = "small"
  }
  option {
    name  = "Medium (2 CPU / 4 GB)"
    value = "medium"
  }
  option {
    name  = "Large  (4 CPU / 8 GB)"
    value = "large"
  }
}

# ── Resource sizing ────────────────────────────────────────────────────────────

locals {
  sizes = {
    small  = { cpu_req = "1", cpu_lim = "2", mem_req = "2Gi", mem_lim = "4Gi" }
    medium = { cpu_req = "2", cpu_lim = "4", mem_req = "4Gi", mem_lim = "8Gi" }
    large  = { cpu_req = "4", cpu_lim = "6", mem_req = "8Gi", mem_lim = "12Gi" }
  }
  size = local.sizes[data.coder_parameter.instance_size.value]

  workspace_namespace = "coder-ws-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}"

  repo_dir = "/home/coder/${basename(trimsuffix(data.coder_parameter.repo_url.value, ".git"))}"

  # Deterministic, no collisions across repeat runs by the same owner. Two
  # different owners could collide on the same workspace name — accepted
  # single-operator-demo scope limitation.
  modernize_branch = "modernize/${data.coder_workspace.me.name}"
}

# ── Workspace namespace ────────────────────────────────────────────────────────

resource "kubernetes_namespace" "workspace" {
  metadata {
    name = local.workspace_namespace
    labels = {
      "coder.com/workspace-id"    = data.coder_workspace.me.id
      "coder.com/workspace-owner" = data.coder_workspace_owner.me.name
    }
  }
}

# ── Network policy — egress allowlist ─────────────────────────────────────────
# Port-based only (DNS/53, HTTP/80, HTTPS/443) — this cluster's VPC CNI enforces
# NetworkPolicy natively but has no Calico/Cilium L7 filtering, so there's no way
# to restrict egress to specific domains (e.g. only api.anthropic.com and
# github.com) yet. Documented gap, not solved here.

resource "kubernetes_network_policy" "workspace_egress" {
  metadata {
    name      = "workspace-egress"
    namespace = kubernetes_namespace.workspace.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      ports {
        port     = "53"
        protocol = "UDP"
      }
    }

    egress {
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }

    egress {
      ports {
        port     = "80"
        protocol = "TCP"
      }
    }
  }
}

# ── Persistent home directory ──────────────────────────────────────────────────

resource "kubernetes_persistent_volume_claim" "home" {
  metadata {
    name      = "home"
    namespace = kubernetes_namespace.workspace.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = "gp3"
    resources {
      requests = { storage = "10Gi" }
    }
  }

  wait_until_bound = false
}

# ── Coder workspace agent ──────────────────────────────────────────────────────

resource "coder_agent" "main" {
  arch = "amd64"
  os   = "linux"

  env = {
    GITHUB_TOKEN = data.coder_external_auth.github.access_token
    # Routes Claude Code through AI Bridge instead of calling Anthropic directly.
    # Set at the agent level (not exported in the startup script) so it's present
    # in every terminal/code-server session the developer opens, not just the
    # one-shot startup script process.
    ANTHROPIC_BASE_URL = "${data.coder_workspace.me.access_url}/api/v2/aibridge/anthropic"
    # ANTHROPIC_AUTH_TOKEN (-> Authorization: Bearer), not ANTHROPIC_API_KEY
    # (-> x-api-key, reserved for a real Anthropic/BYOK key) — centralized
    # mode per docs/ai-coder/ai-gateway/clients/claude-code.md.
    ANTHROPIC_AUTH_TOKEN = var.coder_api_token
    CODER_WORKSPACE_NAME = data.coder_workspace.me.name
  }

  # Blocking: agent doesn't report ready until startup script exits.
  startup_script_behavior = "blocking"

  startup_script = <<-EOT
    #!/bin/bash
    set -e

    # Tools install into $HOME/.local/bin on the PVC — first boot installs, restarts skip.
    mkdir -p "$HOME/.local/bin"
    export PATH="$HOME/.venv/bin:$HOME/.local/bin:$PATH"
    grep -qxF 'export PATH="$HOME/.venv/bin:$HOME/.local/bin:$PATH"' "$HOME/.bashrc" || \
      echo 'export PATH="$HOME/.venv/bin:$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"

    # ── Git identity ───────────────────────────────────────────────────────────
    git config --global user.name  "${data.coder_workspace_owner.me.full_name != "" ? data.coder_workspace_owner.me.full_name : data.coder_workspace_owner.me.name}"
    git config --global user.email "${data.coder_workspace_owner.me.email}"

    # ── Git credentials ────────────────────────────────────────────────────────
    git config --global credential.https://github.com.helper \
      "!f() { echo username=x-access-token; echo password=$${GITHUB_TOKEN}; }; f"

    # ── go-task (drives coder-demo-modernise-flask's own Taskfile) ───────────
    if ! command -v task &>/dev/null; then
      sh -c "$(curl -fsSL https://taskfile.dev/install.sh)" -- -d -b "$HOME/.local/bin" 2>/dev/null
    fi

    # ── Node.js + Claude Code CLI ──────────────────────────────────────────────
    # nvm is the only non-root Node.js install method available in this image.
    export NVM_DIR="$HOME/.nvm"
    if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
      curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
    fi
    # shellcheck source=/dev/null
    source "$NVM_DIR/nvm.sh"
    if ! command -v node &>/dev/null; then
      nvm install --lts --no-progress
    fi
    if ! command -v claude &>/dev/null; then
      npm install -g @anthropic-ai/claude-code@latest --quiet
    fi

    # ── Clone repo and create/checkout the modernization branch ──────────────
    # $HOME is a persistent PVC — on a restart the repo already exists, just
    # make sure we're on the right branch. No auto-pull on restart — don't
    # clobber uncommitted in-progress work.
    REPO_DIR="${local.repo_dir}"
    BRANCH="${local.modernize_branch}"

    if [[ ! -d "$REPO_DIR" ]]; then
      git clone --depth=1 "${data.coder_parameter.repo_url.value}" "$REPO_DIR"
      cd "$REPO_DIR"
      git checkout -b "$BRANCH"
      git push -u origin "$BRANCH"
    else
      cd "$REPO_DIR"
      if [[ "$(git rev-parse --abbrev-ref HEAD)" != "$BRANCH" ]]; then
        git checkout "$BRANCH" 2>/dev/null || git checkout -b "$BRANCH"
      fi
    fi

    # ── Python venv — mirrors a developer's own laptop setup ─────────────────
    # $HOME is a persistent PVC — venv survives restarts, only created once;
    # pip install re-runs every boot (cheap no-op) to pick up requirements.txt changes.
    [[ -d "$HOME/.venv" ]] || python3 -m venv "$HOME/.venv"
    "$HOME/.venv/bin/pip" install --quiet -r "$REPO_DIR/requirements-dev.txt"
  EOT

  metadata {
    display_name = "CPU"
    key          = "cpu_usage"
    script       = "coder stat cpu"
    interval     = 5
    timeout      = 5
  }

  metadata {
    display_name = "Memory"
    key          = "mem_usage"
    script       = "coder stat mem"
    interval     = 5
    timeout      = 5
  }

  metadata {
    display_name = "Disk"
    key          = "disk"
    script       = "coder stat disk --path $HOME"
    interval     = 60
    timeout      = 5
  }
}

# ── App shortcuts ──────────────────────────────────────────────────────────────

module "code_server" {
  source   = "registry.coder.com/coder/code-server/coder"
  version  = "1.5.2"
  agent_id = coder_agent.main.id
  folder   = local.repo_dir

  extensions = ["ms-python.python"]
  settings   = { "workbench.colorTheme" = "Default Dark Modern" }
}

# Not auto-started by the startup script — the developer runs `task run`
# themselves (Flask now, uvicorn after the rewrite), this is just a clickable
# preview tab for whenever that's running.
resource "coder_app" "preview" {
  agent_id     = coder_agent.main.id
  slug         = "preview"
  display_name = "App Preview"
  url          = "http://localhost:8000"
  icon         = "/icon/code.svg"
  subdomain    = false
  share        = "owner"
}

# ── Workspace pod ──────────────────────────────────────────────────────────────

resource "kubernetes_pod" "workspace" {
  count = data.coder_workspace.me.start_count

  metadata {
    name      = "coder-${lower(data.coder_workspace_owner.me.name)}-${lower(data.coder_workspace.me.name)}"
    namespace = kubernetes_namespace.workspace.metadata[0].name
    labels = {
      "app"                       = "coder-workspace"
      "coder.com/workspace-id"    = data.coder_workspace.me.id
      "coder.com/workspace-name"  = data.coder_workspace.me.name
      "coder.com/workspace-owner" = data.coder_workspace_owner.me.name
    }
    annotations = {
      "coder.com/workspace-id" = data.coder_workspace.me.id
    }
  }

  spec {
    security_context {
      run_as_user     = 1000
      run_as_non_root = true
      fs_group        = 1000
    }

    # Prevents lateral movement via the K8s API from a compromised workspace.
    automount_service_account_token = false

    container {
      name    = "workspace"
      image   = "codercom/enterprise-base:ubuntu"
      command = ["/bin/bash", "-c", coder_agent.main.init_script]

      env {
        name  = "CODER_AGENT_TOKEN"
        value = coder_agent.main.token
      }

      resources {
        requests = {
          cpu    = local.size.cpu_req
          memory = local.size.mem_req
        }
        limits = {
          cpu    = local.size.cpu_lim
          memory = local.size.mem_lim
        }
      }

      volume_mount {
        mount_path = "/home/coder"
        name       = "home"
      }
    }

    volume {
      name = "home"
      persistent_volume_claim {
        claim_name = kubernetes_persistent_volume_claim.home.metadata[0].name
      }
    }
  }
}
