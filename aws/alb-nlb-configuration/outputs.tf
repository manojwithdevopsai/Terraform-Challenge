output "vpc_id" {
  value = aws_vpc.main.id
}

output "public_subnet_id" {
  value = aws_subnet.public.id
}

output "private_subnet_ids" {
  value = [for s in aws_subnet.private : s.id]
}

output "alb_internal_dns" {
  value = aws_lb.alb_internal.dns_name
}

output "nlb_dns" {
  value = aws_lb.nlb.dns_name
}

output "private_instance_ids" {
  value = [for i in aws_instance.private_vm : i.id]
}
