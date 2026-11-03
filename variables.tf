variable "rpf_rules_json_file_path" {
  description = "Path to the Remote Port Forwarding JSON export produced by `catocli export rpf_rules` (data.policy.remotePortFwd.policy root)."
  type        = string
}

variable "policy_enabled" {
  description = "Manage the account-level Remote Port Forwarding policy toggle. null leaves the toggle unmanaged; true/false manages it via cato_remote_port_fwd_policy."
  type        = bool
  default     = null
}
