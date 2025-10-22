variable "project_name" {
  description = "Project name"
  type        = string
}

variable "environment" {
  description = "Environment name"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "public_subnet_ids" {
  description = "List of public subnet IDs"
  type        = list(string)
}

variable "health_check_path" {
  description = "Path for health check"
  type        = string
  default     = "/health"
}

variable "container_port" {
  description = "Port exposed by the container"
  type        = number
  default     = 80
}

# Optional: Uncomment when adding HTTPS support
# variable "acm_certificate_arn" {
#   description = "ARN of ACM certificate for HTTPS"
#   type        = string
#   default     = ""
# }
