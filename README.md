# terraform-cato-bulk-rpf-rules

Bulk-manages the Cato **Remote Port Forwarding (remotePortFwd)** policy from a single
JSON export: sections and rules (flat policy - no sub-policies exist for this
type), with ordering and publishing via `cato_bulk_rpf_move_rule`.

## Usage

### Basic Example

```hcl
module "rpf_rules" {
  source                   = "catonetworks/bulk-rpf-rules/cato"
  rpf_rules_json_file_path = "${path.module}/config_data/all_rpf_rules_and_sections.json"
}
```

### JSON Configuration Structure

```bash
catocli export rpf_rules --json-filename all_rpf_rules_and_sections.json
```

Root: `data.policy.remotePortFwd.policy` with `sections[]`, `rules[]`
(wrappers `{audit, rule, properties}`, ids retained for brownfield import),
and `rules_in_sections[]`.

#### Key Fields:

**Sections Array** (`sections[]`): each entry has `section_index` (order in
policy) and `section_name` (display name, also the `for_each` key).

**Rules Array** (`rules[]`): each entry is wrapped as `{audit, rule,
properties}`; the `rule` object carries the RPF-specific fields:
- `externalIp` - allocated IP reference (by `name` or `id`); requires an allocated IP on the tenant
- `externalPortRange` / `internalPortRange` - `{from, to}` port ranges
- `internalIp` - the internal target IP
- `forwardIcmp` - optional, forwards ICMP alongside the port range
- `remoteIPs` - allow/block style lists: `globalIpRange`, `ip`, `ipRange`, `subnet`
- `restrictionType` - e.g. `ALLOW_LIST`
- `tracking` - alert/event settings, with `mailingList`/`subscriptionGroup`/`webhook` recipients

**Rules in Sections Array** (`rules_in_sections[]`): maps rules to sections
with `index_in_section`, `section_name`, and `rule_name`. Rows with
`section_name: ""` are sectionless (rules placed at the policy root).

#### Resources Managed

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

### How Rule Ordering Works

`rules_in_sections[]` is what actually controls ordering - not the position
of entries in `rules[]`/`sections[]`. Each row's `section_name` +
`index_in_section` (and each section's `section_index`) feed
`cato_bulk_rpf_move_rule.all_rpf_rules`, which moves every section and rule
into place and republishes the policy on every apply. Rows with
`section_name: ""` have no managed section to order within, so they're
excluded from the move resource; their order is creation order, and they're
surfaced via the `unordered_rules` output for visibility.

### Parameters

- `rpf_rules_json_file_path` - path to the Remote Port Forwarding JSON export (`data.policy.remotePortFwd.policy` root)
- `policy_enabled` - optional account-level policy toggle; `null` (default) leaves it unmanaged, `true`/`false` manages it via `cato_remote_port_fwd_policy`. RPF ships **disabled** by default on new tenants.
- `allow_empty_policy` - safety guard; fails planning when the JSON has 0 rules unless explicitly set `true` (intentional greenfield/teardown only)

## Working with Existing Rules (Brownfield Deployments)

For brownfield deployments where you have existing Remote Port Forwarding rules in your Cato Management Application, you can use the Cato CLI to export and import these rules into Terraform state.

### Installing and Configuring Cato CLI

1. **Install the Cato CLI:**
   ```bash
   pip3 install catocli
   ```

2. **Configure the CLI with your Cato credentials:**
   ```bash
   catocli configure set
   ```
   This will prompt you for your Cato Management Application credentials and account information.

### Exporting Existing Rules

To export your existing Remote Port Forwarding rules and sections into the JSON format required by this module:

```bash
catocli export rpf_rules --json-filename all_rpf_rules_and_sections.json
```

This command will generate a JSON file containing all your existing RPF rules and sections in the correct format for this Terraform module.

### Importing Existing Rules into Terraform State (native import blocks)

Requires Terraform **>= 1.7**. Every `for_each` address in this module
(`rules_by_name`, `sections_data`) is keyed by name, exactly matching the
exported JSON's `rule.name` / `section_name` fields - that's why the import
blocks below line up one-to-one with the JSON with no re-keying.

<details>
<summary>Option A (recommended) - native Terraform import blocks (migration.tf)</summary>

```hcl
# migration.tf - one-time adoption of existing Remote Port Forwarding rules/sections.
# Place beside the module call (same directory as main.tf), run once, then delete.

locals {
  rpf_migration_json     = jsondecode(file("${path.module}/config_data/all_rpf_rules_and_sections.json"))
  rpf_migration_policy   = local.rpf_migration_json.data.policy.remotePortFwd.policy
  rpf_migration_sections = { for s in local.rpf_migration_policy.sections : s.section_name => s.section_id }
  rpf_migration_rules    = { for rw in local.rpf_migration_policy.rules : rw.rule.name => rw.rule.id }
}

import {
  for_each = local.rpf_migration_sections
  to       = module.rpf_rules.cato_remote_port_fwd_section.sections[each.key]
  id       = each.value
}

import {
  for_each = local.rpf_migration_rules
  to       = module.rpf_rules.cato_remote_port_fwd_rule.rules[each.key]
  id       = each.value
}
```

`cato_bulk_rpf_move_rule` is plan-time orchestration - it republishes the
whole policy on every apply and has no persisted object of its own to
import, so it never appears in `migration.tf`. Same for the optional
`cato_remote_port_fwd_policy` enable/disable toggle: it's a tenant-wide
singleton with no name/`for_each` to key an import block on.

</details>

<details>
<summary>Option B - catocli import rpf_rules_to_tf (imperative alternative)</summary>

```bash
catocli import rpf_rules_to_tf config_data/all_rpf_rules_and_sections.json \
  --module-name module.rpf_rules --auto-approve
terraform plan   # expect: only cato_bulk_rpf_move_rule to add
```

This mutates Terraform state immediately - there's no plan preview before
the import happens. Use it only when Option A isn't practical (e.g.
Terraform < 1.7).

</details>

### Typical Brownfield Workflow

1. Export: `catocli export rpf_rules --json-filename all_rpf_rules_and_sections.json`
2. Write `migration.tf` beside the module call, as in Option A above.
3. Preview: `terraform plan` - expect `N to import, 0 to add, 0 to change, 0
   to destroy`. Any planned **change** (not just import) means the JSON is
   stale relative to the live policy - re-export and regenerate
   `migration.tf` before applying; never let `terraform apply` overwrite the
   live policy from an old backup.
4. Adopt: `terraform apply`.
5. Delete `migration.tf` - it's a one-time migration aid, not steady-state
   config.

Option B (`catocli import rpf_rules_to_tf`) is the alternative when Option A
isn't practical.

### Backup and Restore Workflow

If unintended changes are made directly to rules or sections in the Cato Management Application, you can restore to the last known good state:

1. **Apply your last known good configuration:**
   ```bash
   terraform apply
   ```
   This restores rules, sections, and ordering to match your Terraform configuration and republishes via `cato_bulk_rpf_move_rule`.

2. **Alternatively, re-export and compare:**
   ```bash
   catocli export rpf_rules --json-filename all_rpf_rules_and_sections.json
   # Compare with your existing JSON file to identify drift
   ```

## Using Module Outputs

```hcl
output "rpf_summary" {
  value = {
    counts          = module.rpf_rules.deployment_summary
    section_ids     = module.rpf_rules.section_ids
    rule_ids        = module.rpf_rules.rule_ids
    unordered_rules = module.rpf_rules.unordered_rules
  }
}
```

### Output Use Cases

- **`deployment_summary`**: counts of managed sections/rules, for quick deployment overviews or dashboards
- **`section_ids`**: map of section name to section id, for referencing sections from other configs
- **`rule_ids`**: map of rule name to rule id, for referencing rules from other configs or audit tooling
- **`unordered_rules`**: visibility into `rules_in_sections` rows excluded from `cato_bulk_rpf_move_rule` (sectionless rows); useful for confirming creation-order placement is acceptable

## Known limitations

- Ordering rows with `section_name: ""` are excluded from the move resource
  and surfaced via `unordered_rules`; their order is creation order.
- Run applies with `-parallelism=1` when several module instances share an
  account.
- Only `cato_remote_port_fwd_rule`/`cato_remote_port_fwd_section` support
  import; `cato_bulk_rpf_move_rule` and the `cato_remote_port_fwd_policy`
  toggle are outside the JSON-driven import flow (see above).

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.5.0 |
| <a name="requirement_cato"></a> [cato](#requirement\_cato) | >= 1.3.1 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_cato"></a> [cato](#provider\_cato) | 1.3.1 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [cato_bulk_rpf_move_rule.all_rpf_rules](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/bulk_rpf_move_rule) | resource |
| [cato_remote_port_fwd_policy.policy](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/remote_port_fwd_policy) | resource |
| [cato_remote_port_fwd_rule.rules](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/remote_port_fwd_rule) | resource |
| [cato_remote_port_fwd_section.sections](https://registry.terraform.io/providers/catonetworks/cato/latest/docs/resources/remote_port_fwd_section) | resource |
| [terraform_data.guard_empty_policy](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_allow_empty_policy"></a> [allow\_empty\_policy](#input\_allow\_empty\_policy) | Safety guard: fail planning when the policy JSON contains 0 rules unless explicitly allowed. Protects against a truncated or wrong-tenant export destroying the live policy. Set true only for intentional greenfield/teardown. | `bool` | `false` | no |
| <a name="input_policy_enabled"></a> [policy\_enabled](#input\_policy\_enabled) | Manage the account-level Remote Port Forwarding policy toggle. null leaves the toggle unmanaged; true/false manages it via cato\_remote\_port\_fwd\_policy. | `bool` | `null` | no |
| <a name="input_rpf_rules_json_file_path"></a> [rpf\_rules\_json\_file\_path](#input\_rpf\_rules\_json\_file\_path) | Path to the Remote Port Forwarding JSON export produced by `catocli export rpf_rules` (data.policy.remotePortFwd.policy root). | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_deployment_summary"></a> [deployment\_summary](#output\_deployment\_summary) | Counts of managed Remote Port Forwarding objects. |
| <a name="output_rule_ids"></a> [rule\_ids](#output\_rule\_ids) | Map of rule name to rule id. |
| <a name="output_section_ids"></a> [section\_ids](#output\_section\_ids) | Map of section name to section id. |
| <a name="output_unordered_rules"></a> [unordered\_rules](#output\_unordered\_rules) | rules\_in\_sections rows excluded from cato\_bulk\_rpf\_move\_rule (no managed section to order within). |
<!-- END_TF_DOCS -->
