# terraform-cato-bulk-rpf-rules

Bulk-manages the Cato **Remote Port Forwarding (remotePortFwd)** policy from a single
JSON export: sections and rules (flat policy - no sub-policies exist for this
type), with ordering and publishing via `cato_bulk_rpf_move_rule`.

## Resources managed

| Resource | Keyed by | Notes |
|---|---|---|
| `cato_remote_port_fwd_section.sections` | `section_name` | created `LAST_IN_POLICY`; ordered by the move resource |
| `cato_remote_port_fwd_rule.rules` | rule name | placement: managed section -> `LAST_IN_SECTION`; sectionless -> `LAST_IN_POLICY` |
| `cato_bulk_rpf_move_rule.all_rpf_rules` | - | orders sections (`section_index`) and rules (`index_in_section`) and **publishes** |
| `cato_remote_port_fwd_policy.policy` | - | optional account-level enable/disable toggle (`policy_enabled` variable) |

**Publishing:** the rule/section resources save to the draft policy only -
`cato_bulk_rpf_move_rule` is this stack's single publisher. Remote Port Forwarding ships
**disabled** on new tenants - set `policy_enabled = true` (or enable it in
the CMA) for published rules to take effect.

## Input JSON

```bash
catocli export rpf_rules --json-filename all_rpf_rules_and_sections.json
```

Root: `data.policy.remotePortFwd.policy` with `sections[]`, `rules[]`
(wrappers `{audit, rule, properties}`, ids retained for brownfield import),
and `rules_in_sections[]`. Rule fields: externalIp (allocated IP ref), external/internalPortRange, internalIp, forwardIcmp, remoteIPs allow/block lists, restrictionType, tracking. Requires an allocated IP on the tenant.

## Usage

```hcl
module "rpf_rules" {
  source                   = "catonetworks/bulk-rpf-rules/cato"
  rpf_rules_json_file_path = "${path.module}/config_data/all_rpf_rules_and_sections.json"
}
```

## Brownfield import

```bash
catocli import rpf_rules_to_tf config_data/all_rpf_rules_and_sections.json \
  --module-name module.rpf_rules --auto-approve
terraform plan   # expect: only cato_bulk_rpf_move_rule to add
```

## Known limitations

- Ordering rows with `section_name: ""` are excluded from the move resource
  and surfaced via `unordered_rules`; their order is creation order.
- Run applies with `-parallelism=1` when several module instances share an
  account.
