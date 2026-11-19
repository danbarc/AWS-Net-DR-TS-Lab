output "vpc_id" {
  description = "ID of the lab VPC"
  value       = aws_vpc.lab.id
}

output "private_subnet_id" {
  description = "ID of the private subnet"
  value       = aws_subnet.private.id
}

output "private_route_table_id" {
  description = "ID of the private route table (check this during troubleshooting)"
  value       = aws_route_table.private.id
}

output "private_instance_id" {
  description = "ID of the private EC2 instance (use with SSM)"
  value       = aws_instance.private.id
}

output "private_instance_private_ip" {
  description = "Private IP of the lab instance"
  value       = aws_instance.private.private_ip
}

output "flow_log_group" {
  description = "CloudWatch Log Group for VPC Flow Logs"
  value       = aws_cloudwatch_log_group.flow_logs.name
}

output "ssm_connect_command" {
  description = "Command to start an SSM session to the private instance"
  value       = "aws ssm start-session --target ${aws_instance.private.id} --region ${var.aws_region}"
}

output "enable_private_outbound" {
  description = "Current state of the private outbound route"
  value       = var.enable_private_outbound
}

output "nat_gateway_id" {
  description = "NAT Gateway ID (for Reachability Analyzer tests)"
  value       = aws_nat_gateway.lab.id
}
