
output "bucket_arn" {
  description = "The ARN of the created S3 bucket."
  value       = aws_s3_bucket._.arn
}

output "bucket" {
  description = "The S3 bucket resource."
  value       = aws_s3_bucket._
}
