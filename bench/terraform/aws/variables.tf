variable "region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-east-1"
}

variable "prefix" {
  description = "Short prefix for resource names. Lowercase letters/numbers/hyphens."
  type        = string
  default     = "regbench"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,12}$", var.prefix))
    error_message = "prefix must be 2-13 chars, start with a letter, lowercase letters/digits/hyphens only."
  }
}

variable "instance_type_registry" {
  description = <<-EOT
    EC2 instance type for the registry server. Must have local NVMe instance store.

    m6idn.2xlarge is the default: identical 8 vCPU / 32 GiB / 474 GB NVMe to the
    m6id.2xlarge this used to be, but with a 12.5 Gbps *sustained* network
    baseline rather than 3.125. On m6id a high-concurrency run drains its burst
    credits partway through and the throughput curve bends for a reason that has
    nothing to do with the registry under test.
  EOT
  type        = string
  default     = "m6idn.2xlarge"
}

variable "instance_type_loadtester" {
  description = <<-EOT
    EC2 instance type for the load tester. Network/CPU-bound; no local storage needed.

    Sized so the client is never the constraint: c6in.4xlarge has 16 vCPU and a
    25 Gbps baseline, double the registry's 12.5, so a flattening curve is the
    registry saturating and not the generator running out of headroom.
  EOT
  type        = string
  default     = "c6in.4xlarge"
}

variable "operator_cidr" {
  description = "CIDR allowed to SSH into the VMs (your IP/32). Use: curl -s ifconfig.me"
  type        = string
}

variable "admin_username" {
  description = "Linux admin username. Must match the Ubuntu AMI default user."
  type        = string
  default     = "ubuntu"
}

variable "ssh_key_path" {
  description = "Path where the generated SSH private key is written locally."
  type        = string
  default     = "~/.ssh/registry-bench-aws"
}
