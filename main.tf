# terraform-cato-bulk-rpf-rules
#
# Bulk-manages the Cato Remote Port Forwarding (remotePortFwd) policy from one JSON
# export produced by `catocli export rpf_rules`:
#   sections[] / rules[] / rules_in_sections[] - flat policy, no sub-policies.
# cato_bulk_rpf_move_rule applies ordering and republishes.
# Rule fields: externalIp (allocated IP ref), external/internalPortRange, internalIp, forwardIcmp, remoteIPs allow/block lists, restrictionType, tracking. Requires an allocated IP on the tenant.

locals {
  rpf_json = jsondecode(file("${var.rpf_rules_json_file_path}"))
  rpf      = local.rpf_json.data.policy.remotePortFwd.policy

  sections_data_raw      = try(local.rpf.sections, [])
  rules_data_raw         = try(local.rpf.rules, [])
  rules_in_sections_data = try(local.rpf.rules_in_sections, [])

  sections_data = {
    for s in local.sections_data_raw : s.section_name => s
  }

  rules_by_name = {
    for rw in local.rules_data_raw : rw.rule.name => rw
  }

  move_section_data = {
    for name, s in local.sections_data : name => {
      section_index = s.section_index
    }
  }

  move_rule_data = {
    for row in local.rules_in_sections_data :
    row.rule_name => {
      index_in_section = row.index_in_section
      section_name     = row.section_name
    }
    if row.section_name != "" && contains(keys(local.sections_data), row.section_name)
  }

  unordered_rules_data = [
    for row in local.rules_in_sections_data : row
    if !contains(keys(local.move_rule_data), try(row.rule_name, ""))
  ]

  rule_bodies = {
    for name, rw in local.rules_by_name : name => merge(
      {
        name        = rw.rule.name
        enabled     = try(rw.rule.enabled, true)
        external_ip = can(rw.rule.externalIp.name) ? { name = rw.rule.externalIp.name } : { id = rw.rule.externalIp.id }
        external_port_range = {
          from = tostring(rw.rule.externalPortRange.from)
          to   = tostring(rw.rule.externalPortRange.to)
        }
        internal_ip = rw.rule.internalIp
        internal_port_range = {
          from = tostring(rw.rule.internalPortRange.from)
          to   = tostring(rw.rule.internalPortRange.to)
        }
        restriction_type = try(rw.rule.restrictionType, "ALLOW_LIST")
      },
      try(rw.rule.description, "") != "" ? { description = rw.rule.description } : {},
      try(rw.rule.forwardIcmp, null) != null ? { forward_icmp = rw.rule.forwardIcmp } : {},
      anytrue([
        try(length(rw.rule.remoteIPs.globalIpRange), 0) > 0,
        try(length(rw.rule.remoteIPs.ip), 0) > 0,
        try(length(rw.rule.remoteIPs.ipRange), 0) > 0,
        try(length(rw.rule.remoteIPs.subnet), 0) > 0,
        ]) ? {
        remote_ips = merge(
          try(length(rw.rule.remoteIPs.globalIpRange), 0) > 0 ? { global_ip_range = [for x in rw.rule.remoteIPs.globalIpRange : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(rw.rule.remoteIPs.ip), 0) > 0 ? { ip = rw.rule.remoteIPs.ip } : {},
          try(length(rw.rule.remoteIPs.ipRange), 0) > 0 ? { ip_range = [for r in rw.rule.remoteIPs.ipRange : { from = r.from, to = r.to }] } : {},
          try(length(rw.rule.remoteIPs.subnet), 0) > 0 ? { subnet = rw.rule.remoteIPs.subnet } : {}
        )
      } : {},
      try(rw.rule.tracking.enabled, false) ? {
        tracking = merge(
          {
            enabled   = rw.rule.tracking.enabled
            frequency = try(rw.rule.tracking.frequency, "HOURLY")
          },
          try(length(rw.rule.tracking.mailingList), 0) > 0 ? { mailing_list = [for x in rw.rule.tracking.mailingList : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(rw.rule.tracking.subscriptionGroup), 0) > 0 ? { subscription_group = [for x in rw.rule.tracking.subscriptionGroup : can(x.name) ? { name = x.name } : { id = x.id }] } : {},
          try(length(rw.rule.tracking.webhook), 0) > 0 ? { webhook = [for x in rw.rule.tracking.webhook : can(x.name) ? { name = x.name } : { id = x.id }] } : {}
        )
      } : {}
    )
  }
}

# Optional account-level policy toggle (Remote Port Forwarding ships disabled on new
# tenants - without enabling it, published rules have no effect).
resource "cato_remote_port_fwd_policy" "policy" {
  count   = var.policy_enabled == null ? 0 : 1
  enabled = var.policy_enabled
}

resource "cato_remote_port_fwd_section" "sections" {
  for_each = local.sections_data
  at = {
    position = "LAST_IN_POLICY"
  }
  section = {
    name = each.value.section_name
  }
}

resource "cato_remote_port_fwd_rule" "rules" {
  depends_on = [cato_remote_port_fwd_section.sections]
  for_each   = local.rules_by_name

  at = contains(keys(local.sections_data), each.value.rule.section.name) ? {
    position = "LAST_IN_SECTION"
    ref      = cato_remote_port_fwd_section.sections[each.value.rule.section.name].id
    } : {
    position = "LAST_IN_POLICY"
  }

  rule = local.rule_bodies[each.key]
}

# Ordering + republish on changes.
resource "cato_bulk_rpf_move_rule" "all_rpf_rules" {
  depends_on = [cato_remote_port_fwd_section.sections, cato_remote_port_fwd_rule.rules]

  section_data = local.move_section_data
  rule_data    = local.move_rule_data
}
