variable "region" {
  description = "Region of the runner. us-east-1 keeps it next to the Neon and Supabase projects."
  type        = string
  default     = "us-east-1"
}

variable "account_id" {
  description = "AWS account the runner lives in; the provider refuses any other."
  type        = string
}

variable "name" {
  description = "Name prefix for every resource."
  type        = string
  default     = "neon-exit-runner"
}

variable "vpc_id" {
  description = "VPC that gets the private subnet and the NAT gateway."
  type        = string
}

variable "public_subnet_id" {
  description = "Existing public subnet (route to an internet gateway) that hosts the NAT gateway."
  type        = string
}

variable "private_subnet_cidr" {
  description = "CIDR of the new private subnet; must be free inside the VPC."
  type        = string
  default     = "172.31.96.0/20"
}

variable "availability_zone" {
  description = "AZ of the private subnet; the instance type must be offered there."
  type        = string
  default     = "us-east-1a"
}

variable "instance_type" {
  description = "Instance type with local NVMe for the dump."
  type        = string
  default     = "m6id.4xlarge"
}

variable "ami_ssm_parameter" {
  description = "SSM public parameter that resolves to the AMI."
  type        = string
  default     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size. The dump goes to the NVMe instance store at /scratch, not here."
  type        = number
  default     = 50
}

variable "db_owner_secret_name" {
  description = "Secrets Manager name of the target database owner credential. Created empty; the value is written out of band by whoever holds it."
  type        = string
  default     = "neon-exit/relayhistory-legacy/postgres-owner"
}

variable "copy_urls_secret_name" {
  description = "Secrets Manager name of the Cloud copy connection URLs. Created empty; written out of band and read on the runner."
  type        = string
  default     = "neon-exit/cloud/copy-urls"
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    project   = "neon-exit"
    managed   = "terraform"
    ephemeral = "true"
  }
}
