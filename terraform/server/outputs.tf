output "address" {
  description = "Point each company's app, api. and files. names here."
  value       = aws_eip.server.public_ip
}

output "open_a_shell" {
  value = "aws ssm start-session --region ${var.region} --target ${aws_instance.server.id}"
}

output "releases_bucket" {
  value = aws_s3_bucket.releases.id
}

output "backup_command" {
  description = "For BACKUP_OFFSITE_CMD in each company's deployment.env."
  value       = "BACKUP_OFFSITE_CMD='aws s3 cp --only-show-errors --region ${var.dr_region} \"$BACKUP_FILE\" \"s3://${aws_s3_bucket.backups.id}/$CLIENT_SLUG/\"'"
}
