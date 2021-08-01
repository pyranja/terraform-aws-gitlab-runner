
variable "name" {
  description = "The name of this gitlab runner. Used as the default Name tag on each EC2 Instance and to namespace all the resources created by this module."
  type        = string
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
  })
}

variable "autoscale" {
  description = "Gitlab runner autoscaling configuration."
  type = object({
    instance_type = string
    max_worker    = number
    min_worker    = number
  })
}

# ----------------------------------------------------------------------------------------------------------------------
# OPTIONAL PARAMETERS
# These variables may be optionally passed in by the templates using this module to overwite the defaults.
# ----------------------------------------------------------------------------------------------------------------------

variable "tags" {
  description = "A map of key value pairs that represents custom tags to apply to resources."
  type        = map(string)
  default     = {}
}

variable "cache" {
  description = "Provide an existing S3 bucket as shared cache. If not set, a bucket is created and configured as cache for this runner only."
  type = object({
    id     = string
    arn    = string
    region = string
  })
  default = null
}
