# Advanced Topics - Technical Deep Dive

This document addresses the advanced follow-up questions from the DevOps Engineer exercise and provides detailed implementation guidance.

## Table of Contents
1. [Secrets Management](#1-secrets-management)
2. [Blue/Green & Canary Deployments](#2-bluegreen--canary-deployments)
3. [Auto-Scaling Implementation](#3-auto-scaling-implementation)
4. [Observability with CloudWatch & Datadog](#4-observability-with-cloudwatch--datadog)
5. [ECS EC2 vs Fargate Trade-offs](#5-ecs-ec2-vs-fargate-trade-offs)

---

## 1. Secrets Management

### Overview
Handling sensitive data like Rails master keys, database passwords, and API tokens requires a secure, auditable approach.

### Current Implementation

The infrastructure supports secrets through:
- **SSM Parameter Store**: For non-sensitive environment variables
- **AWS Secrets Manager**: For sensitive credentials

### Best Practices Implementation

#### A. Rails Master Key

**Step 1: Store in AWS Secrets Manager**

```bash
# Create secret
aws secretsmanager create-secret \
  --name "rails-api/production/RAILS_MASTER_KEY" \
  --description "Rails master key for credentials encryption" \
  --secret-string "$(cat config/master.key)" \
  --region us-east-1

# Add tags
aws secretsmanager tag-resource \
  --secret-id "rails-api/production/RAILS_MASTER_KEY" \
  --tags Key=Environment,Value=production Key=Application,Value=rails-api
```

**Step 2: Grant ECS Task Execution Role Access**

This is already implemented in `infra/modules/ecs/main.tf`:

```hcl
resource "aws_iam_role_policy" "ecs_task_execution_ssm" {
  # ... existing policy ...

  Statement = [
    {
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue"
      ]
      Resource = "arn:aws:secretsmanager:*:*:secret:rails-api/production/*"
    }
  ]
}
```

**Step 3: Reference in Task Definition**

Uncomment and use the secrets section in `infra/modules/ecs/main.tf`:

```hcl
container_definitions = jsonencode([{
  # ... existing config ...

  secrets = [
    {
      name      = "RAILS_MASTER_KEY"
      valueFrom = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:rails-api/production/RAILS_MASTER_KEY"
    }
  ]
}])
```

#### B. Database Credentials

**Option 1: Secrets Manager with Rotation**

```hcl
# In a new file: infra/modules/ecs/secrets.tf

resource "aws_secretsmanager_secret" "db_password" {
  name                    = "${var.project_name}/${var.environment}/DB_PASSWORD"
  description             = "Database password with auto-rotation"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = jsonencode({
    username = "rails_app"
    password = random_password.db_password.result
    host     = aws_db_instance.main.address  # If using RDS
    port     = 5432
    database = "rails_production"
  })
}

resource "random_password" "db_password" {
  length  = 32
  special = true
}

# Enable automatic rotation (requires Lambda function)
resource "aws_secretsmanager_secret_rotation" "db_password" {
  secret_id           = aws_secretsmanager_secret.db_password.id
  rotation_lambda_arn = aws_lambda_function.rotate_secret.arn

  rotation_rules {
    automatically_after_days = 30
  }
}
```

**Option 2: RDS IAM Authentication**

For PostgreSQL/MySQL, use IAM database authentication:

```hcl
resource "aws_db_instance" "main" {
  # ... existing config ...
  iam_database_authentication_enabled = true
}

# Task role policy for RDS IAM auth
resource "aws_iam_role_policy" "ecs_task_rds" {
  role = aws_iam_role.ecs_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["rds-db:connect"]
      Resource = "arn:aws:rds-db:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:dbuser:${aws_db_instance.main.resource_id}/rails_app"
    }]
  })
}
```

Rails configuration:
```ruby
# config/database.yml
production:
  adapter: postgresql
  host: <%= ENV['DB_HOST'] %>
  port: 5432
  database: rails_production
  username: rails_app
  password: <%= `aws rds generate-db-auth-token --hostname #{ENV['DB_HOST']} --port 5432 --username rails_app --region us-east-1` %>
  sslmode: require
```

#### C. Third-Party API Keys

**Using SSM Parameter Store (Cost-Effective)**

```bash
# Store API key
aws ssm put-parameter \
  --name "/rails-api/production/STRIPE_API_KEY" \
  --value "sk_live_xxxxx" \
  --type "SecureString" \
  --key-id "alias/aws/ssm" \
  --region us-east-1
```

Reference in task definition:
```hcl
secrets = [
  {
    name      = "STRIPE_API_KEY"
    valueFrom = "arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:parameter/rails-api/production/STRIPE_API_KEY"
  }
]
```

### Security Best Practices

1. **Never Commit Secrets**: Use `.gitignore` and pre-commit hooks
2. **Principle of Least Privilege**: Grant minimum required permissions
3. **Rotation**: Implement automatic secret rotation
4. **Audit Logging**: Enable CloudTrail for secret access
5. **Encryption**: Use KMS for encryption at rest
6. **Separation**: Different secrets per environment

### Audit and Compliance

```bash
# Monitor secret access
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=ResourceName,AttributeValue=rails-api/production/RAILS_MASTER_KEY \
  --max-results 10

# List all secrets
aws secretsmanager list-secrets \
  --filters Key=tag-key,Values=Application Key=tag-value,Values=rails-api
```

---

## 2. Blue/Green & Canary Deployments

### Blue/Green Deployment with ECS

Blue/Green deployment provides zero-downtime deployments with instant rollback capability.

#### Implementation with AWS CodeDeploy

**Step 1: Add CodeDeploy Resources**

Create `infra/modules/ecs/codedeploy.tf`:

```hcl
# CodeDeploy Application
resource "aws_codedeploy_app" "main" {
  compute_platform = "ECS"
  name             = "${var.project_name}-${var.environment}"
}

# CodeDeploy Service Role
resource "aws_iam_role" "codedeploy" {
  name = "${var.project_name}-${var.environment}-codedeploy-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "codedeploy.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "codedeploy" {
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
  role       = aws_iam_role.codedeploy.name
}

# CodeDeploy Deployment Group
resource "aws_codedeploy_deployment_group" "main" {
  app_name               = aws_codedeploy_app.main.name
  deployment_group_name  = "${var.project_name}-${var.environment}-dg"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE", "DEPLOYMENT_STOP_ON_ALARM"]
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }

    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 5
    }
  }

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.main.name
    service_name = aws_ecs_service.main.name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [var.alb_listener_arn]
      }

      target_group {
        name = var.blue_target_group_name
      }

      target_group {
        name = var.green_target_group_name
      }
    }
  }
}
```

**Step 2: Create Two Target Groups**

Update `infra/modules/alb/main.tf`:

```hcl
resource "aws_lb_target_group" "blue" {
  name        = "${var.project_name}-${var.environment}-blue"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = var.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
  }

  deregistration_delay = 30
}

resource "aws_lb_target_group" "green" {
  name        = "${var.project_name}-${var.environment}-green"
  port        = var.container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = var.health_check_path
    healthy_threshold   = 2
    unhealthy_threshold = 3
    timeout             = 5
    interval            = 30
  }

  deregistration_delay = 30
}
```

**Step 3: Update ECS Service**

```hcl
resource "aws_ecs_service" "main" {
  # ... existing config ...

  deployment_controller {
    type = "CODE_DEPLOY"
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.blue.arn
    container_name   = var.project_name
    container_port   = var.container_port
  }
}
```

**Step 4: Update GitHub Actions Workflow**

```yaml
- name: Deploy with CodeDeploy
  run: |
    # Create AppSpec
    cat > appspec.json << EOF
    {
      "version": 1,
      "Resources": [{
        "TargetService": {
          "Type": "AWS::ECS::Service",
          "Properties": {
            "TaskDefinition": "${{ steps.task-def.outputs.task-definition-arn }}",
            "LoadBalancerInfo": {
              "ContainerName": "rails-api",
              "ContainerPort": 80
            }
          }
        }
      }]
    }
    EOF

    # Create deployment
    DEPLOYMENT_ID=$(aws deploy create-deployment \
      --application-name rails-api-production \
      --deployment-group-name rails-api-production-dg \
      --revision '{"revisionType":"AppSpecContent","appSpecContent":{"content":"'$(cat appspec.json | jq -c)'"}}' \
      --query 'deploymentId' \
      --output text)

    echo "Deployment ID: $DEPLOYMENT_ID"

    # Wait for deployment
    aws deploy wait deployment-successful --deployment-id $DEPLOYMENT_ID
```

### Canary Deployment

Canary releases gradually shift traffic to the new version, allowing you to monitor before full rollout.

**Step 1: Configure CodeDeploy for Canary**

```hcl
resource "aws_codedeploy_deployment_group" "main" {
  # ... existing config ...

  deployment_config_name = "CodeDeployDefault.ECSCanary10Percent5Minutes"
  # Or create custom: CodeDeployDefault.ECSCanary10Percent15Minutes
}
```

**Available Canary Configurations**:
- `ECSCanary10Percent5Minutes`: 10% traffic for 5 min, then 100%
- `ECSCanary10Percent15Minutes`: 10% traffic for 15 min, then 100%
- Custom configurations supported

**Step 2: Add CloudWatch Alarms for Auto-Rollback**

```hcl
resource "aws_cloudwatch_metric_alarm" "high_error_rate" {
  alarm_name          = "${var.project_name}-${var.environment}-high-error-rate"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = "60"
  statistic           = "Sum"
  threshold           = "10"
  alarm_description   = "This metric monitors 5xx errors"
  treat_missing_data  = "notBreaching"

  dimensions = {
    TargetGroup  = aws_lb_target_group.green.arn_suffix
    LoadBalancer = var.alb_arn_suffix
  }
}

resource "aws_codedeploy_deployment_group" "main" {
  # ... existing config ...

  alarm_configuration {
    alarms  = [aws_cloudwatch_metric_alarm.high_error_rate.alarm_name]
    enabled = true
  }

  auto_rollback_configuration {
    enabled = true
    events  = [
      "DEPLOYMENT_FAILURE",
      "DEPLOYMENT_STOP_ON_ALARM",
      "DEPLOYMENT_STOP_ON_REQUEST"
    ]
  }
}
```

### Linear Deployment

For more gradual rollouts:

```hcl
deployment_config_name = "CodeDeployDefault.ECSLinear10PercentEvery1Minutes"
# Or: ECSLinear10PercentEvery3Minutes
```

This shifts 10% of traffic every N minutes until 100%.

---

## 3. Auto-Scaling Implementation

### Application Auto-Scaling for ECS

#### Basic CPU-Based Scaling

Add to `infra/modules/ecs/autoscaling.tf`:

```hcl
# Auto Scaling Target
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.main.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# CPU-Based Scaling Policy
resource "aws_appautoscaling_policy" "ecs_cpu" {
  name               = "${var.project_name}-${var.environment}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 70.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

# Memory-Based Scaling Policy
resource "aws_appautoscaling_policy" "ecs_memory" {
  name               = "${var.project_name}-${var.environment}-memory-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 80.0
    scale_in_cooldown  = 300
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
  }
}
```

Add variables to `infra/modules/ecs/variables.tf`:

```hcl
variable "min_capacity" {
  description = "Minimum number of tasks"
  type        = number
  default     = 2
}

variable "max_capacity" {
  description = "Maximum number of tasks"
  type        = number
  default     = 10
}
```

#### Request-Based Scaling

Scale based on ALB request count:

```hcl
resource "aws_appautoscaling_policy" "ecs_requests" {
  name               = "${var.project_name}-${var.environment}-request-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value = 1000.0  # Target 1000 requests per task

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${var.alb_arn_suffix}/${var.target_group_arn_suffix}"
    }
  }
}
```

#### Custom Metric Scaling (Latency)

Scale based on response time:

```hcl
resource "aws_cloudwatch_metric_alarm" "high_latency" {
  alarm_name          = "${var.project_name}-high-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = "2"
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = "60"
  statistic           = "Average"
  threshold           = "1.0"  # 1 second

  dimensions = {
    LoadBalancer = var.alb_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }
}

resource "aws_appautoscaling_policy" "scale_up" {
  name               = "${var.project_name}-scale-up"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  step_scaling_policy_configuration {
    adjustment_type         = "ChangeInCapacity"
    cooldown                = 60
    metric_aggregation_type = "Average"

    step_adjustment {
      metric_interval_lower_bound = 0
      scaling_adjustment          = 2
    }
  }
}

resource "aws_cloudwatch_metric_alarm_action" "scale_up" {
  alarm_name = aws_cloudwatch_metric_alarm.high_latency.alarm_name
  alarm_actions = [
    aws_appautoscaling_policy.scale_up.arn
  ]
}
```

#### Scheduled Scaling

Scale for predictable traffic patterns:

```hcl
resource "aws_appautoscaling_scheduled_action" "scale_up_morning" {
  name               = "${var.project_name}-scale-up-morning"
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  schedule           = "cron(0 7 * * MON-FRI)"  # 7 AM weekdays

  scalable_target_action {
    min_capacity = 5
    max_capacity = 20
  }
}

resource "aws_appautoscaling_scheduled_action" "scale_down_evening" {
  name               = "${var.project_name}-scale-down-evening"
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  schedule           = "cron(0 18 * * MON-FRI)"  # 6 PM weekdays

  scalable_target_action {
    min_capacity = 2
    max_capacity = 10
  }
}
```

### Testing Auto-Scaling

```bash
# Generate load with Apache Bench
ab -n 10000 -c 100 http://YOUR-ALB-DNS/health

# Or use Artillery for more realistic load
npm install -g artillery
artillery quick --count 100 --num 1000 http://YOUR-ALB-DNS/health

# Monitor scaling
watch -n 5 'aws ecs describe-services \
  --cluster rails-api-production-cluster \
  --services rails-api-production-service \
  --query "services[0].{Desired:desiredCount,Running:runningCount}" \
  --output table'
```

---

## 4. Observability with CloudWatch & Datadog

### CloudWatch Logs Integration

Already implemented in `infra/modules/ecs/main.tf`:

```hcl
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.project_name}-${var.environment}"
  retention_in_days = 7  # Increase for production
}
```

#### Enhanced Logging in Rails

Add to `config/environments/production.rb`:

```ruby
Rails.application.configure do
  # Log to STDOUT for CloudWatch
  logger           = ActiveSupport::Logger.new(STDOUT)
  logger.formatter = config.log_formatter
  config.logger    = ActiveSupport::TaggedLogging.new(logger)

  # Structured JSON logging
  config.log_formatter = proc do |severity, datetime, progname, msg|
    {
      timestamp: datetime.iso8601,
      level: severity,
      message: msg,
      request_id: Thread.current[:request_id],
      hostname: Socket.gethostname
    }.to_json + "\n"
  end
end
```

#### CloudWatch Insights Queries

```
# Find errors in last hour
fields @timestamp, @message
| filter @message like /ERROR/
| sort @timestamp desc
| limit 100

# Track response times
fields @timestamp, duration
| filter @message like /Completed/
| parse @message "Completed * * in *ms" as status, path, duration
| stats avg(duration), max(duration), pct(duration, 95) by bin(5m)

# Track memory usage
filter @type = "REPORT"
| fields @timestamp, @memoryUsed / 1000 / 1000 as memoryUsedMB
| sort @timestamp desc
```

### CloudWatch Dashboards

Create `infra/cloudwatch_dashboard.tf`:

```hcl
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project_name}-${var.environment}-dashboard"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/ECS", "CPUUtilization", { stat = "Average" }],
            [".", "MemoryUtilization", { stat = "Average" }]
          ]
          period = 300
          stat   = "Average"
          region = "us-east-1"
          title  = "ECS Resource Utilization"
        }
      },
      {
        type = "metric"
        properties = {
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", { stat = "Average" }],
            ["...", { stat = "p95" }],
            ["...", { stat = "p99" }]
          ]
          period = 60
          region = "us-east-1"
          title  = "Response Time Percentiles"
        }
      }
    ]
  })
}
```

### Datadog Integration

#### Step 1: Add Datadog Agent as Sidecar

Update task definition in `infra/modules/ecs/main.tf`:

```hcl
container_definitions = jsonencode([
  {
    name  = var.project_name
    image = var.container_image
    # ... existing config ...
  },
  {
    name      = "datadog-agent"
    image     = "public.ecr.aws/datadog/agent:latest"
    essential = true

    environment = [
      {
        name  = "DD_SITE"
        value = "datadoghq.com"
      },
      {
        name  = "ECS_FARGATE"
        value = "true"
      },
      {
        name  = "DD_APM_ENABLED"
        value = "true"
      },
      {
        name  = "DD_LOGS_ENABLED"
        value = "true"
      },
      {
        name  = "DD_LOGS_CONFIG_CONTAINER_COLLECT_ALL"
        value = "true"
      }
    ]

    secrets = [
      {
        name      = "DD_API_KEY"
        valueFrom = "arn:aws:secretsmanager:region:account:secret:datadog/api-key"
      }
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.ecs.name
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "datadog"
      }
    }
  }
])
```

#### Step 2: Install Datadog APM in Rails

Add to `Gemfile`:

```ruby
gem 'ddtrace', '~> 1.0'
```

Configure in `config/initializers/datadog.rb`:

```ruby
require 'datadog/tracing'

Datadog.configure do |c|
  c.tracing.instrument :rails
  c.tracing.instrument :faraday
  c.tracing.instrument :redis if defined?(Redis)
  c.tracing.instrument :pg if defined?(PG)

  # Service configuration
  c.service = 'rails-api'
  c.env = ENV['RAILS_ENV']
  c.version = ENV['COMMIT_SHA'] || 'unknown'

  # Sampling
  c.tracing.sampling.default_rate = 0.1  # Sample 10% of requests
end
```

#### Step 3: Custom Metrics

```ruby
# app/controllers/application_controller.rb
class ApplicationController < ActionController::API
  around_action :track_request_metrics

  private

  def track_request_metrics
    start_time = Time.current
    yield
  ensure
    duration = (Time.current - start_time) * 1000

    Datadog::Statsd.new.gauge(
      'api.request.duration',
      duration,
      tags: [
        "controller:#{controller_name}",
        "action:#{action_name}",
        "status:#{response.status}"
      ]
    )
  end
end
```

### Alternative: AWS X-Ray

For AWS-native distributed tracing:

```ruby
# Gemfile
gem 'aws-xray-sdk', '~> 0.11.0'

# config/initializers/xray.rb
require 'aws-xray-sdk/facets/rails/railtie'

XRay.recorder.configure(
  emitter: XRay::Emitter.new,
  sampler: XRay::LocalizedSampler.new,
  name: 'rails-api'
)
```

Update task definition:

```hcl
{
  name      = "xray-daemon"
  image     = "amazon/aws-xray-daemon"
  essential = false
  cpu       = 32
  memory    = 256

  portMappings = [{
    containerPort = 2000
    protocol      = "udp"
  }]
}
```

---

## 5. ECS EC2 vs Fargate Trade-offs

### Comprehensive Comparison

| Factor | ECS Fargate | ECS EC2 |
|--------|------------|---------|
| **Management** | Serverless, no server management | Manage EC2 instances, patching, scaling |
| **Pricing Model** | Per-task (vCPU + memory + duration) | Per-instance (EC2 pricing) |
| **Cost at Small Scale** | More expensive | Less cost-effective (idle capacity) |
| **Cost at Large Scale** | Can be 20-40% more expensive | More economical with Reserved Instances |
| **Cold Start** | ~1-2 seconds | Instant (instances already running) |
| **Resource Efficiency** | Pay only for what you use | May have idle capacity |
| **Customization** | Limited (can't SSH, no root) | Full control (custom AMIs, kernel tuning) |
| **Networking** | awsvpc mode only | Bridge, host, awsvpc modes |
| **Storage** | 20 GB ephemeral (expandable to 200 GB) | EBS volumes, instance store |
| **Launch Time** | 30-60 seconds | Instant for running instances |
| **Security** | Isolated, no shared kernel | Potential noisy neighbor issues |
| **Compliance** | Easier (no OS to audit) | More complex (OS + runtime) |
| **Scaling** | Fast, no capacity planning | Requires cluster capacity |

### Cost Analysis Example

**Scenario**: Running 10 tasks, 24/7

**Fargate Costs** (0.25 vCPU, 0.5 GB):
```
Per task per hour:
- vCPU: 0.25 × $0.04048 = $0.01012
- Memory: 0.5 GB × $0.004445 = $0.002223
- Total per task/hour: $0.012343
- 10 tasks × 730 hours = $90.10/month
```

**EC2 Costs** (t3.small instances):
```
Per instance:
- t3.small: $0.0208/hour = $15.18/month
- 5 instances (2 tasks each): $75.90/month

With Reserved Instances (1-year, no upfront):
- t3.small: $0.0124/hour = $9.05/month
- 5 instances: $45.25/month
```

**Break-even Point**: ~5-10 tasks running constantly

### When to Use Fargate

✅ **Best for**:
- Getting started / prototyping
- Variable workloads
- Microservices with unpredictable traffic
- Small to medium scale (< 50 tasks)
- Short-lived tasks
- Security/compliance requirements (isolation)
- Teams without ops expertise

❌ **Avoid when**:
- Very large scale (> 100 tasks)
- Cost is primary concern
- Need custom kernel modules
- Require GPU instances
- Need persistent storage beyond 200 GB

### When to Use EC2

✅ **Best for**:
- Large scale (> 100 tasks)
- Predictable workloads (Reserved Instances)
- Need specific instance types (GPU, high memory)
- Require host-level customization
- Cost optimization is critical
- Bin-packing multiple services

❌ **Avoid when**:
- Limited ops team
- Variable workloads
- Security isolation is critical
- Don't want to manage infrastructure

### Hybrid Approach

Use both with Capacity Providers:

```hcl
resource "aws_ecs_capacity_provider" "fargate" {
  name = "FARGATE"
}

resource "aws_ecs_capacity_provider" "fargate_spot" {
  name = "FARGATE_SPOT"
}

resource "aws_ecs_capacity_provider" "ec2" {
  name = "${var.project_name}-ec2-capacity-provider"

  auto_scaling_group_provider {
    auto_scaling_group_arn = aws_autoscaling_group.ecs.arn

    managed_scaling {
      maximum_scaling_step_size = 10
      minimum_scaling_step_size = 1
      status                    = "ENABLED"
      target_capacity           = 80
    }
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name = aws_ecs_cluster.main.name

  capacity_providers = [
    "FARGATE",
    "FARGATE_SPOT",
    aws_ecs_capacity_provider.ec2.name
  ]

  default_capacity_provider_strategy {
    capacity_provider = aws_ecs_capacity_provider.ec2.name
    weight            = 70
    base              = 2
  }

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 30
  }
}
```

This configuration:
- Uses EC2 for 70% of base load (cost-effective)
- Uses Fargate Spot for 30% (saves ~70% on Fargate cost)
- Auto-scales EC2 cluster based on demand
- Falls back to Fargate if EC2 capacity exhausted

### Migration Path: Fargate → EC2

1. **Create Launch Template**:
```hcl
resource "aws_launch_template" "ecs" {
  name_prefix   = "${var.project_name}-"
  image_id      = data.aws_ami.ecs_optimized.id
  instance_type = "t3.small"

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance.name
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    echo ECS_CLUSTER=${aws_ecs_cluster.main.name} >> /etc/ecs/ecs.config
    EOF
  )

  network_interfaces {
    associate_public_ip_address = true
    security_groups            = [aws_security_group.ecs_instances.id]
  }
}
```

2. **Create Auto Scaling Group**:
```hcl
resource "aws_autoscaling_group" "ecs" {
  name                = "${var.project_name}-ecs-asg"
  vpc_zone_identifier = var.private_subnet_ids
  min_size            = 2
  max_size            = 10
  desired_capacity    = 2

  launch_template {
    id      = aws_launch_template.ecs.id
    version = "$Latest"
  }

  tag {
    key                 = "AmazonECSManaged"
    value               = true
    propagate_at_launch = true
  }
}
```

3. **Update Service**:
```hcl
resource "aws_ecs_service" "main" {
  # Change from:
  launch_type = "FARGATE"

  # To:
  launch_type = "EC2"

  # Remove awsvpc requirement (optional)
  network_configuration {
    subnets = var.private_subnet_ids
  }
}
```

### Cost Optimization Recommendations

1. **Use Fargate Spot** (70% savings):
```hcl
capacity_provider_strategy {
  capacity_provider = "FARGATE_SPOT"
  weight            = 100
}
```

2. **Right-size Tasks**:
```bash
# Analyze actual usage
aws cloudwatch get-metric-statistics \
  --namespace AWS/ECS \
  --metric-name CPUUtilization \
  --dimensions Name=ServiceName,Value=rails-api-production-service \
  --start-time 2025-10-01T00:00:00Z \
  --end-time 2025-10-22T23:59:59Z \
  --period 3600 \
  --statistics Average,Maximum

# Adjust resources accordingly
container_cpu    = 128  # If < 50% utilization
container_memory = 256  # If < 50% utilization
```

3. **Implement Auto-Scaling** to match demand
4. **Use Savings Plans** (Fargate) or **Reserved Instances** (EC2)
5. **Schedule Scale-Down** during off-peak hours

---

## Summary

This document covers advanced implementation patterns for:
1. ✅ Secrets management with AWS Secrets Manager and SSM
2. ✅ Blue/Green and Canary deployments with CodeDeploy
3. ✅ Auto-scaling based on CPU, memory, requests, and custom metrics
4. ✅ Comprehensive observability with CloudWatch, Datadog, and X-Ray
5. ✅ Detailed ECS Fargate vs EC2 trade-off analysis with cost comparisons

All implementations follow AWS Well-Architected Framework principles and production best practices.

---
