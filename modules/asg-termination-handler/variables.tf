
variable "name" {
  description = "The name of this termination handler. Used to namespace resources."
  type        = string
}

variable "autoscaling_group" {
  description = "The autoscaling group that is monitored for terminations."
  type = object({
    name = string
    arn  = string
  })
}

# ----------------------------------------------------------------------------------------------------------------------
# OPTIONAL PARAMETERS
# These variables may be optionally passed in by the templates using this module to overwrite the defaults.
# ----------------------------------------------------------------------------------------------------------------------

variable "cleanup_script_path" {
  description = "Path to script that is invoked on termination (defaults to /bin/termination-handler.sh)"
  type        = string
  default     = "/bin/termination-handler.sh"
}

variable "tags" {
  description = "A map of key value pairs that represents custom tags to apply to resources."
  type        = map(string)
  default     = {}
}
