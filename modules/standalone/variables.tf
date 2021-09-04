
variable "name" {
  description = "The name of this gitlab runner. Used as the default Name tag on each EC2 Instance and to namespace all the resources created by this module."
  type        = string

  validation {
    condition     = length(var.name) <= 28
    error_message = "The runner name may consist of up to 28 characters. Otherwise worker host names exceed docker limits."
  }
}

variable "subnet_id" {
  description = "ID of the subnet where the runner should be deployed (e.g., subnet-abcd1234)."
  type        = string
}

variable "gitlab" {
  description = "Gitlab runner configuration."
  type = object({
    url   = string
    token = string
    tags  = list(string)
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
  description = "Gitlab runner S3 bucket for caching."
  type = object({
    id     = string
    arn    = string
    region = string
  })
}

# ----------------------------------------------------------------------------------------------------------------------
# OPTIONAL PARAMETERS
# These variables may be optionally passed in by the templates using this module to overwrite the defaults.
# ----------------------------------------------------------------------------------------------------------------------

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

variable "max_concurrent_jobs" {
  description = "Maximum number of jobs to run in parallel per runner instance (defaults to 2 per available vcpu)."
  type        = number
  default     = null

  validation {
    condition     = var.max_concurrent_jobs == null ? true : var.max_concurrent_jobs > 0
    error_message = "Tha maximum number of concurrent jobs must be at least 1. Otherwise no jobs are executed."
  }
}
