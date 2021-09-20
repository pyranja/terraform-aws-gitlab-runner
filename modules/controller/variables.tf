
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

variable "controller_ami_id" {
  description = "The Amazon Machine Image (AMI) to run on the manager instance (defaults to latest amzn linux 2 AMI)."
  type        = string
  default     = null
}

variable "controller_instance_type" {
  description = "The type of EC2 instance to use for the manager instance (defaults to t3.micro)."
  type        = string
  default     = "t3.micro"
}
