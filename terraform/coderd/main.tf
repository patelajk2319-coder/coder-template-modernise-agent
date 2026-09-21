data "coderd_organization" "default" {
  is_default = true
}

locals {
  governance_description = "owner: ${var.template_owner} | cost-centre: ${var.template_cost_centre} | team: ${var.template_team} | env: ${var.template_env}"

  default_ttl_ms   = tonumber(regex("^([0-9]+)h$", var.template_default_ttl)[0]) * 3600000
  activity_bump_ms = tonumber(regex("^([0-9]+)h$", var.template_activity_bump)[0]) * 3600000

  provisioner_tags = var.provisioner_tag == "" ? [] : [{
    name  = split("=", var.provisioner_tag)[0]
    value = split("=", var.provisioner_tag)[1]
  }]
}

resource "coderd_template" "modernize_flask_workspace" {
  name            = "modernize-flask-workspace"
  display_name    = "Modernize Flask Workspace"
  description     = local.governance_description
  organization_id = data.coderd_organization.default.id

  default_ttl_ms   = local.default_ttl_ms
  activity_bump_ms = local.activity_bump_ms

  versions = [{
    directory        = "${path.module}/../../templates/modernize-flask-workspace"
    name             = "v${var.template_version}"
    active           = true
    provisioner_tags = local.provisioner_tags
    tf_vars = [{
      name  = "coder_api_token"
      value = var.ai_bridge_coder_api_token
    }]
  }]
}
