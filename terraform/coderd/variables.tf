variable "coder_url" {
  description = "URL Terraform can reach the Coder API at (coder-demo-eks's port-forward — CODER_URL in .env)"
  type        = string
}

variable "coder_api_token" {
  description = "Long-lived Coder API token for the coderd provider, minted on coder-demo-eks via task init"
  type        = string
  sensitive   = true
}

# Distinct from coder_api_token above even though both are sourced from the same
# .env value: coder_api_token authenticates this Terraform push (the coderd
# provider), this one gets fed into the workspace template's own AI-Bridge-routing
# variable via tf_vars, at workspace runtime. One secret, two different consumers.
variable "ai_bridge_coder_api_token" {
  description = "Coder API token supplied to the workspace template as its AI Bridge (fake Anthropic) API key"
  type        = string
  sensitive   = true
}

variable "template_version" {
  description = "Version string from this repo's VERSION file — becomes the pushed template version's name"
  type        = string
}

variable "template_owner" {
  description = "Governance metadata: owner"
  type        = string
}

variable "template_cost_centre" {
  description = "Governance metadata: cost centre"
  type        = string
}

variable "template_team" {
  description = "Governance metadata: team"
  type        = string
}

variable "template_env" {
  description = "Governance metadata: environment"
  type        = string
}

variable "template_default_ttl" {
  description = "Idle autostop TTL for workspaces from this template, as a whole number of hours followed by 'h' (e.g. 4h)"
  type        = string
}

variable "template_activity_bump" {
  description = "How much active use extends the autostop deadline, as a whole number of hours followed by 'h' (e.g. 1h)"
  type        = string
}

variable "provisioner_tag" {
  description = "Optional single key=value provisioner tag to route builds to an external provisioner (e.g. team=demo). Blank uses the control plane's built-in provisioners."
  type        = string
  default     = ""
}
