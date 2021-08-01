
variable "name" {
  description = "The name of this runner cache. Used in the bucket name and to namespace other resources."
  type        = string
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

variable "expiration_days" {
  description = "Expire cache contents that are older than X days."
  type        = number
  default     = 7
}
