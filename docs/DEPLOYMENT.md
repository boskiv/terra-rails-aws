# Rails API Deployment Guide

Complete guide for deploying a Ruby on Rails API to AWS using Docker, Terraform, and GitHub Actions with tag-based deployments.

## Table of Contents
- [Quick Start](#quick-start-30-minutes)
- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Local Development](#local-development)
- [AWS Infrastructure Setup](#aws-infrastructure-setup)
- [GitHub Actions CI/CD Setup](#github-actions-cicd-setup)
- [Tag-Based Deployment](#tag-based-deployment)
- [Deployment Quick Reference](#deployment-quick-reference)
- [Verification](#verification)
- [Advanced Topics](#advanced-topics)
- [Troubleshooting](#troubleshooting)
- [FAQ](#faq)

---

## Quick Start (30 Minutes)

Get deployed to AWS in 30 minutes with these streamlined steps.

### Prerequisites Checklist
- [ ] AWS Account with admin access
- [ ] AWS CLI configured (`aws configure`)
- [ ] Docker installed
- [ ] Terraform >= 1.0
- [ ] GitHub repository created

### Step 1: Test Locally (2 min)
```bash
docker build -t rails-api .
docker run -p 8080:80 --rm rails-api
curl http://localhost:8080/health  # Should return {"status":"ok"}
```

### Step 2: AWS OIDC Setup (5 min)
```bash
# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Set your GitHub info
GITHUB_ORG="your-github-username"
REPO_NAME="your-repo-name"

# Create OIDC provider (once per AWS account)
aws iam create-open-id-connect-provider \
  --url "https://token.actions.githubusercontent.com" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1"
```

### Step 3: Create IAM Role (3 min)
```bash
# Create trust policy
cat > github-trust-policy.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
      },
      "StringLike": {
        "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}/${REPO_NAME}:*"
      }
    }
  }]
}
EOF

# Create role and attach policies
aws iam create-role \
  --role-name GitHubActionsDeployRole \
  --assume-role-policy-document file://github-trust-policy.json

aws iam attach-role-policy \
  --role-name GitHubActionsDeployRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser

aws iam attach-role-policy \
  --role-name GitHubActionsDeployRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess

# Create Terraform policy
cat > terraform-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["ec2:*", "elasticloadbalancing:*", "iam:*", "logs:*", "ssm:*"],
    "Resource": "*"
  }]
}
EOF

aws iam put-role-policy \
  --role-name GitHubActionsDeployRole \
  --policy-name TerraformPolicy \
  --policy-document file://terraform-policy.json
```

### Step 4: Configure GitHub (2 min)
1. Go to GitHub repository → Settings → Secrets and variables → Actions
2. Add secret: `AWS_ROLE_TO_ASSUME` = `arn:aws:iam::YOUR-ACCOUNT-ID:role/GitHubActionsDeployRole`

### Step 5: Initialize Terraform (3 min)
```bash
cd infra
terraform init
terraform validate
terraform plan
```

### Step 6: Deploy (15 min)
```bash
# Push code (no deployment yet)
git add .
git commit -m "Initial deployment"
git push origin main

# Create version tag to trigger deployment
git tag -a v1.0.0 -m "Initial production release"
git push origin v1.0.0

# Monitor: GitHub → Actions → Deploy to AWS ECS
```

### Step 7: Verify (2 min)
```bash
cd infra
ALB_DNS=$(terraform output -raw alb_dns_name)
curl http://$ALB_DNS/health  # Should return {"status":"ok"}
```

**🎉 Done!** Your API is live. Continue reading for detailed documentation.

---

## Overview

This project deploys a Rails API with the following architecture:
- **Application**: Ruby on Rails 7.1 API-only app with `/health` endpoint
- **Containerization**: Docker with multi-stage build
- **Container Registry**: AWS ECR
- **Compute**: AWS ECS on Fargate
- **Load Balancer**: Application Load Balancer (ALB)
- **Networking**: VPC with public/private subnets, NAT Gateways
- **IaC**: Terraform with modular design
- **CI/CD**: GitHub Actions with OIDC authentication

## Prerequisites

### Required Tools
- Docker Desktop or Docker Engine
- AWS CLI v2
- Terraform >= 1.0
- Git
- Ruby 3.4.7 (for local development)

### AWS Account Requirements
- AWS account with administrative access
- AWS CLI configured with appropriate credentials
- Permissions to create:
  - VPC, Subnets, Internet Gateway, NAT Gateway
  - ECR Repository
  - ECS Cluster, Task Definitions, Services
  - Application Load Balancer
  - IAM Roles and Policies
  - CloudWatch Log Groups
  - SSM Parameters

## Local Development

### 1. Test the Application Locally

```bash
# Install dependencies
bundle install

# Run the Rails server
bin/rails server

# Test the health endpoint
curl http://localhost:3000/health
# Expected: {"status":"ok"}
```

### 2. Test with Docker

```bash
# Build the Docker image
docker build -t rails-api .

# Run the container (using Thruster on port 80)
docker run -p 8080:80 --rm rails-api

# Test the health endpoint
curl http://localhost:8080/health
# Expected: {"status":"ok"}

# Alternative: Run with direct Puma access on port 3000
docker run -p 8080:3000 --rm \
  -e PORT=3000 \
  rails-api ./bin/rails server -b 0.0.0.0
```

## AWS Infrastructure Setup

### 1. Configure AWS Provider

The Terraform configuration uses the `us-east-1` region by default. Update `infra/variables.tf` if needed:

```hcl
variable "aws_region" {
  default = "us-east-1"  # Change if needed
}
```

### 2. Set Up Remote State (Optional but Recommended)

Create an S3 bucket and DynamoDB table for Terraform state:

```bash
# Create S3 bucket for state
aws s3api create-bucket \
  --bucket rails-api-terraform-state \
  --region us-east-1

# Enable versioning
aws s3api put-bucket-versioning \
  --bucket rails-api-terraform-state \
  --versioning-configuration Status=Enabled

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name rails-api-terraform-locks \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
  --region us-east-1
```

Uncomment the backend configuration in `infra/provider.tf`:

```hcl
backend "s3" {
  bucket         = "rails-api-terraform-state"
  key            = "terraform.tfstate"
  region         = "us-east-1"
  dynamodb_table = "rails-api-terraform-locks"
  encrypt        = true
}
```

### 3. Initialize Terraform

```bash
cd infra
terraform init
terraform validate
terraform fmt -recursive
```

### 4. Plan Infrastructure

```bash
# Review what will be created
terraform plan

# Save plan to file
terraform plan -out=tfplan
```

### 5. Deploy Infrastructure (Manual)

For the first deployment, you can deploy manually:

```bash
# Apply the plan
terraform apply tfplan

# Or apply directly
terraform apply -auto-approve
```

**Note**: The initial deployment might fail because no Docker image exists in ECR yet. This is expected - GitHub Actions will push the first image.

## GitHub Actions CI/CD Setup

### 1. Set Up AWS OIDC Provider

Create an OIDC provider for GitHub Actions:

```bash
# Get your GitHub organization/username
GITHUB_ORG="your-github-org"
REPO_NAME="your-repo-name"

# Create OIDC provider (only needed once per AWS account)
aws iam create-open-id-connect-provider \
  --url "https://token.actions.githubusercontent.com" \
  --client-id-list "sts.amazonaws.com" \
  --thumbprint-list "6938fd4d98bab03faadb97b34396831e3780aea1"
```

### 2. Create IAM Role for GitHub Actions

Create `github-actions-role-trust-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::YOUR_ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:YOUR_GITHUB_ORG/YOUR_REPO_NAME:*"
        }
      }
    }
  ]
}
```

Create the role:

```bash
# Replace YOUR_ACCOUNT_ID with your AWS account ID
aws iam create-role \
  --role-name GitHubActionsDeployRole \
  --assume-role-policy-document file://github-actions-role-trust-policy.json

# Attach policies (adjust as needed for least privilege)
aws iam attach-role-policy \
  --role-name GitHubActionsDeployRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser

aws iam attach-role-policy \
  --role-name GitHubActionsDeployRole \
  --policy-arn arn:aws:iam::aws:policy/AmazonECS_FullAccess

# Create custom policy for Terraform
cat > terraform-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:*",
        "elasticloadbalancing:*",
        "iam:*",
        "logs:*",
        "ssm:*",
        "secretsmanager:*"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name GitHubActionsDeployRole \
  --policy-name TerraformPolicy \
  --policy-document file://terraform-policy.json
```

### 3. Configure GitHub Secrets

Add the following secret to your GitHub repository:

1. Go to your repository on GitHub
2. Navigate to Settings → Secrets and variables → Actions
3. Add the following secret:
   - `AWS_ROLE_TO_ASSUME`: `arn:aws:iam::YOUR_ACCOUNT_ID:role/GitHubActionsDeployRole`

### 4. Update Workflow Variables

Edit `.github/workflows/deploy.yml` and update these environment variables if needed:

```yaml
env:
  AWS_REGION: us-east-1
  ECR_REPOSITORY: rails-api-production
  ECS_SERVICE: rails-api-production-service
  ECS_CLUSTER: rails-api-production-cluster
  ECS_TASK_DEFINITION_FAMILY: rails-api-production
  CONTAINER_NAME: rails-api
```

## Deployment

### Automatic Deployment (Recommended)

The workflow is configured for tag-based deployments, providing better control over production releases:

```bash
# Commit and push your changes (without triggering deployment)
git add .
git commit -m "Add new feature"
git push origin main

# Create and push a version tag to trigger deployment
git tag -a v1.0.0 -m "Release version 1.0.0"
git push origin v1.0.0
```

The workflow will:
1. Build and push Docker image to ECR (tagged with version tag, commit SHA, and `latest`)
2. Run Terraform plan and apply
3. Update ECS service with new image
4. Verify deployment by checking `/health` endpoint
5. Generate deployment summary

### Manual Deployment

You can also trigger the deployment manually:

1. Go to GitHub Actions tab
2. Select "Deploy to AWS ECS" workflow
3. Click "Run workflow"
4. Select the branch and run

### First-Time Deployment

For the first deployment:

1. Push code to trigger the workflow
2. The workflow will create all infrastructure
3. Push image to ECR
4. Deploy to ECS
5. Verify health check

**Note**: The first deployment takes 10-15 minutes due to:
- VPC and NAT Gateway creation
- ECR repository setup
- ECS cluster initialization
- ALB provisioning and health checks

## Verification

### Check Deployment Status

1. **GitHub Actions**: Monitor the workflow progress
2. **AWS Console**:
   - ECS: Check service status and running tasks
   - ALB: Verify target group health
   - CloudWatch: Check logs

### Test the Application

```bash
# Get the ALB DNS name from Terraform output
cd infra
terraform output alb_dns_name

# Test the health endpoint
curl http://YOUR-ALB-DNS-NAME/health
# Expected: {"status":"ok"}

# Or use the full URL output
terraform output health_check_url
```

### Monitor Logs

```bash
# Stream ECS logs
aws logs tail /ecs/rails-api-production --follow --region us-east-1

# View specific task logs
aws ecs describe-tasks \
  --cluster rails-api-production-cluster \
  --tasks $(aws ecs list-tasks --cluster rails-api-production-cluster --query 'taskArns[0]' --output text) \
  --region us-east-1
```

## Tag-Based Deployment

The deployment workflow uses version tags for controlled releases, enabling semantic versioning and easy rollbacks.

### How It Works

Deployments trigger automatically when you push a version tag matching `v*` (e.g., `v1.0.0`, `v1.2.3`, `v2.0.0-beta`).

**On tag push:**
1. Docker image is built and tagged with version tag, commit SHA, and `latest`
2. Image is pushed to ECR
3. Terraform updates infrastructure
4. ECS deploys new tasks
5. Health checks verify deployment

### Creating Releases

#### Standard Release
```bash
# 1. Make changes and commit
git add .
git commit -m "Add new feature"
git push origin main

# 2. Create version tag
git tag -a v1.0.0 -m "Release v1.0.0 - Initial production release"
git push origin v1.0.0

# 3. Monitor deployment in GitHub Actions
```

#### Semantic Versioning

Follow [SemVer](https://semver.org/) for version numbers (MAJOR.MINOR.PATCH):

- **Patch** (`v1.0.1`) - Bug fixes, backwards compatible
- **Minor** (`v1.1.0`) - New features, backwards compatible
- **Major** (`v2.0.0`) - Breaking changes

```bash
# Patch release (bug fix)
git tag -a v1.0.1 -m "Fix health check timeout"
git push origin v1.0.1

# Minor release (new feature)
git tag -a v1.1.0 -m "Add /status endpoint"
git push origin v1.1.0

# Major release (breaking change)
git tag -a v2.0.0 -m "Update API to v2"
git push origin v2.0.0
```

#### Pre-Release Versions

For testing before production:

```bash
# Beta release
git tag -a v1.0.0-beta.1 -m "Beta release for testing"
git push origin v1.0.0-beta.1

# Release candidate
git tag -a v1.0.0-rc.1 -m "Release candidate"
git push origin v1.0.0-rc.1

# Alpha release
git tag -a v1.0.0-alpha.1 -m "Alpha release"
git push origin v1.0.0-alpha.1
```

### Viewing Versions

```bash
# List all tags
git tag

# View latest tag
git describe --tags --abbrev=0

# List tags with dates
git tag -l --format='%(refname:short) - %(creatordate:short)'

# View tag details
git show v1.0.0
```

### Rollback

If a deployment fails, rollback by deploying a previous version:

**Option 1: Create new tag at previous commit**
```bash
git checkout v1.0.0
git tag -a v1.0.2 -m "Rollback to stable version"
git push origin v1.0.2
```

**Option 2: Manual rollback via AWS**
```bash
# Get previous task definition
aws ecs describe-services \
  --cluster rails-api-production-cluster \
  --services rails-api-production-service \
  --query 'services[0].deployments[1].taskDefinition' \
  --output text

# Update service with previous task definition
aws ecs update-service \
  --cluster rails-api-production-cluster \
  --service rails-api-production-service \
  --task-definition <previous-task-def> \
  --force-new-deployment
```

### Tag Management

```bash
# Delete local tag
git tag -d v1.0.0

# Delete remote tag
git push origin :refs/tags/v1.0.0

# Or use this syntax
git push origin --delete v1.0.0
```

### Best Practices

1. **Always use annotated tags** (`-a` flag) with descriptive messages
2. **Test on main branch** before creating release tags
3. **Use semantic versioning** consistently
4. **Keep a CHANGELOG** documenting each release
5. **Tag naming**: Always use `v` prefix (e.g., `v1.0.0`)
6. **Never reuse tags** - create new versions instead

## Advanced Topics

### Secrets Management

To add secrets like `RAILS_MASTER_KEY`:

1. **Store in AWS Secrets Manager**:
```bash
aws secretsmanager create-secret \
  --name rails-api/production/RAILS_MASTER_KEY \
  --secret-string "your-master-key-here" \
  --region us-east-1
```

2. **Update ECS Task Definition** in `infra/modules/ecs/main.tf`:
```hcl
secrets = [
  {
    name      = "RAILS_MASTER_KEY"
    valueFrom = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:rails-api/production/RAILS_MASTER_KEY"
  }
]
```

### Blue/Green Deployment

To implement blue/green deployment:

1. Update ECS service deployment configuration:
```hcl
deployment_controller {
  type = "CODE_DEPLOY"
}
```

2. Set up AWS CodeDeploy with ECS blue/green deployment
3. Update GitHub Actions workflow to use CodeDeploy

### Canary Releases

For canary releases with ECS:

1. Use AWS App Mesh for traffic splitting
2. Or implement using multiple ECS services with weighted target groups

### Auto-Scaling

Add auto-scaling to ECS service in `infra/modules/ecs/main.tf`:

```hcl
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = 10
  min_capacity       = 2
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.main.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "ecs_cpu" {
  name               = "${var.project_name}-${var.environment}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = 70.0
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
```

### HTTPS with ACM

To enable HTTPS:

1. **Request ACM Certificate**:
```bash
aws acm request-certificate \
  --domain-name api.yourdomain.com \
  --validation-method DNS \
  --region us-east-1
```

2. **Uncomment HTTPS listener** in `infra/modules/alb/main.tf`
3. **Add certificate ARN** to variables

### CloudWatch Monitoring

The infrastructure includes:
- Container Insights enabled on ECS cluster
- CloudWatch log group with 7-day retention
- ALB access logs (can be enabled)

For custom metrics, add to Rails app:
```ruby
# config/initializers/cloudwatch.rb
require 'aws-sdk-cloudwatch'

CLOUDWATCH = Aws::CloudWatch::Client.new(region: 'us-east-1')

# Send custom metrics
CLOUDWATCH.put_metric_data({
  namespace: 'RailsAPI',
  metric_data: [
    {
      metric_name: 'RequestCount',
      value: 1,
      unit: 'Count'
    }
  ]
})
```

### Datadog Integration

To integrate Datadog:

1. Add Datadog agent as sidecar container in task definition
2. Set Datadog API key in Secrets Manager
3. Configure Datadog agent environment variables

## Troubleshooting

### Common Issues

**1. ECS Tasks Failing to Start**
```bash
# Check task logs
aws ecs describe-tasks \
  --cluster rails-api-production-cluster \
  --tasks $(aws ecs list-tasks --cluster rails-api-production-cluster --query 'taskArns[0]' --output text) \
  --query 'tasks[0].stopCode'

# View CloudWatch logs
aws logs tail /ecs/rails-api-production --follow
```

**2. Health Check Failing**
- Verify `/health` endpoint works in container
- Check security group rules
- Ensure container port matches ALB target group port
- Increase health check grace period

**3. GitHub Actions OIDC Errors**
- Verify OIDC provider exists
- Check IAM role trust policy
- Confirm repository name in trust policy matches exactly

**4. Terraform State Lock**
```bash
# If state is locked, force unlock (use with caution)
terraform force-unlock LOCK_ID
```

**5. ECR Image Pull Errors**
- Verify ECS task execution role has ECR permissions
- Check image tag exists in ECR
- Ensure ECR repository name matches

### Debugging Commands

```bash
# Check ECS service events
aws ecs describe-services \
  --cluster rails-api-production-cluster \
  --services rails-api-production-service \
  --query 'services[0].events[0:5]'

# List running tasks
aws ecs list-tasks \
  --cluster rails-api-production-cluster \
  --desired-status RUNNING

# Check ALB target health
aws elbv2 describe-target-health \
  --target-group-arn $(terraform output -raw target_group_arn)

# View Terraform state
terraform show

# SSH into ECS task (if exec enabled)
aws ecs execute-command \
  --cluster rails-api-production-cluster \
  --task TASK_ID \
  --container rails-api \
  --interactive \
  --command "/bin/bash"
```

## Deployment Quick Reference

Quick reference for common deployment tasks.

### Deploy New Version

```bash
# 1. Make changes and commit
git add .
git commit -m "Your changes"
git push origin main

# 2. Create and push version tag
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0

# 3. Monitor: GitHub → Actions → Deploy to AWS ECS
```

### Version Numbering

| Type | Command | When to Use |
|------|---------|-------------|
| **Patch** | `git tag v1.0.1` | Bug fixes |
| **Minor** | `git tag v1.1.0` | New features (backwards compatible) |
| **Major** | `git tag v2.0.0` | Breaking changes |
| **Beta** | `git tag v1.0.0-beta.1` | Testing |
| **RC** | `git tag v1.0.0-rc.1` | Release candidate |

### View Tags

```bash
# List all tags
git tag

# View latest tag
git describe --tags --abbrev=0

# View tag details
git show v1.0.0
```

### Delete Tags

```bash
# Local
git tag -d v1.0.0

# Remote
git push origin :refs/tags/v1.0.0
```

### Rollback

```bash
# Create new tag at previous commit
git checkout v1.0.0
git tag v1.0.2
git push origin v1.0.2
```

### Force Redeploy

```bash
aws ecs update-service \
  --cluster rails-api-production-cluster \
  --service rails-api-production-service \
  --force-new-deployment
```

### Check Deployment Status

```bash
# GitHub Actions
gh run list --workflow=deploy.yml

# ECR images
aws ecr list-images --repository-name rails-api-production

# Current ECS version
aws ecs describe-services \
  --cluster rails-api-production-cluster \
  --services rails-api-production-service \
  --query 'services[0].taskDefinition'

# Application health
curl http://<ALB-DNS>/health
```

### Common Issues

| Issue | Solution |
|-------|----------|
| Tag doesn't trigger deployment | Ensure tag starts with `v` (e.g., `v1.0.0`) |
| Wrong version deployed | Check tag was created at correct commit: `git show v1.0.0` |
| Need immediate redeploy | Use force deployment or create new patch version |

## FAQ

### Q: How do I handle database migrations?

For database migrations, add a migration task:

```hcl
resource "aws_ecs_task_definition" "migrate" {
  family = "${var.project_name}-migrate"
  # ... same config as main task ...

  container_definitions = jsonencode([{
    name = "migrate"
    image = var.container_image
    command = ["bin/rails", "db:migrate"]
    # ... other settings ...
  }])
}
```

Run before deployment:
```bash
aws ecs run-task \
  --cluster rails-api-production-cluster \
  --task-definition rails-api-migrate \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-xxx],securityGroups=[sg-xxx]}"
```

### Q: What are the costs?

Estimated monthly costs (us-east-1):
- **VPC**: Free (data transfer costs apply)
- **NAT Gateway**: ~$32/month per AZ ($64 for 2 AZs)
- **ALB**: ~$16/month + data processed
- **ECS Fargate**: ~$15/month (2 tasks, 0.25 vCPU, 0.5 GB each)
- **ECR**: $0.10/GB/month
- **CloudWatch**: Free tier covers most logging
- **Total**: ~$100-120/month

**Cost Optimization**:
- Use single NAT Gateway (reduces HA)
- Reduce ECS task count to 1
- Use spot pricing for non-production
- Enable S3 VPC endpoint to reduce NAT costs

### Q: How do I destroy the infrastructure?

```bash
cd infra
terraform destroy -auto-approve
```

**Note**: Manually delete ECR images first if the repository has many images.

### Q: ECS on EC2 vs Fargate?

**Fargate** (Current Setup):
- Pros: Serverless, no server management, pay per task
- Cons: Higher per-task cost, less control

**EC2**:
- Pros: Lower cost at scale, more control, can use reserved instances
- Cons: Need to manage instances, patching, scaling

Switch to EC2 by changing `launch_type` in `infra/modules/ecs/main.tf`:
```hcl
resource "aws_ecs_service" "main" {
  launch_type = "EC2"  # Change from FARGATE
  # Add capacity provider strategy
  # Create ECS instances
}
```

## Additional Resources

- [AWS ECS Best Practices](https://docs.aws.amazon.com/AmazonECS/latest/bestpracticesguide/intro.html)
- [Terraform AWS Provider Docs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [GitHub Actions OIDC](https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services)
- [Rails Docker Guide](https://guides.rubyonrails.org/getting_started_with_docker.html)

## Support

For issues or questions:
1. Check the troubleshooting section
2. Review AWS CloudWatch logs
3. Check GitHub Actions workflow logs
4. Review Terraform plan output

---
