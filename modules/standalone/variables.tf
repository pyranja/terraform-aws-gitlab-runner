
variable "name" {
  description = "The name of this gitlab runner. Used as the default Name tag on each EC2 Instance and to namespace all the resources created by this module."
  type        = string

  validation {
    condition     = length(var.name) <= 28
    error_message = "The runner name may consist of up to 28 characters. Otherwise worker host names exceed docker limits."
  }
}

variable "subnet_id" {
  description = "ID of the subnet where the runner should be deployed, e.g. subnet-abcd1234 (specify either this or subnet_id)."
  type        = string
  default     = null
}

variable "subnets" {
  description = "VPC subnet ids to use for runners (specify either this or subnet_id)."
  type        = list(string)
  default     = []
}

variable "gitlab" {
  description = "Gitlab runner configuration."
  type = object({
    url  = string
    tags = list(string)
  })
}

variable "gitlab_token" {
  description = "Reference the AWS secrets manager secret that holds the runner registration token."
  type = object({
    arn = string
  })
}

variable "autoscale" {
  description = "Gitlab runner autoscaling configuration."
  type = object({
    instance_type = string
    volume_size   = number
    max_worker    = number
    min_worker    = number
  })
}

variable "cache" {
  description = "Gitlab runner S3 bucket for caching (null to disable shared cache)."
  type = object({
    id     = string
    arn    = string
    region = string
  })
  default = null
}

# ----------------------------------------------------------------------------------------------------------------------
# OPTIONAL PARAMETERS
# These variables may be optionally passed in by the templates using this module to overwrite the defaults.
# ----------------------------------------------------------------------------------------------------------------------

variable "docker_default_cidr" {
  description = "Override the default address pool of the docker daemon (default 192.168.0.0/16)."
  type        = string
  default     = "192.168.0.0/16"
}

variable "tags" {
  description = "A map of key value pairs that represents custom tags to apply to resources."
  type        = map(string)
  default     = {}
}

variable "ami_id" {
  description = "The Amazon Machine Image (AMI) to run on the instance (defaults to latest amzn linux 2 AMI)."
  type        = string
  default     = null
}

variable "concurrency_factor" {
  description = "Number of concurrent jobs to allow per available cpu (default 2)."
  type        = number
  default     = 2

  validation {
    condition     = var.concurrency_factor > 0
    error_message = "The concurrency factor must be at least 1. Otherwise no jobs are executed."
  }
}

variable "max_concurrent_jobs" {
  description = "Maximum number of jobs to run in parallel per runner instance (defaults to var.concurrency_factor per available vcpu)."
  type        = number
  default     = null

  validation {
    condition     = var.max_concurrent_jobs == null ? true : var.max_concurrent_jobs > 0
    error_message = "The maximum number of concurrent jobs must be at least 1. Otherwise no jobs are executed."
  }
}

variable "permissions_boundary" {
  description = "arn of the iam permission boundary policy to add to created roles"
  type        = string
  default     = null
}
