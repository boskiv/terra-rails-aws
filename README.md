# Rails API - AWS ECS Deployment

Production-ready Ruby on Rails API deployed to AWS ECS using Docker, Terraform, and GitHub Actions with tag-based deployments.

## Features

🐳 Docker • ☁️ AWS ECS Fargate • 🏗️ Terraform • 🚀 GitHub Actions • 🏷️ Tag Deployments • 📊 Monitoring • 🔒 Secure

## Quick Start

```bash
# Test locally
docker build -t rails-api .
docker run -p 8080:80 rails-api
curl http://localhost:8080/health  # {"status":"ok"}

# Deploy to AWS (after setup)
git tag -a v1.0.0 -m "Initial release"
git push origin v1.0.0
```

## Documentation

📖 **[Complete documentation in `docs/`](docs/)**

| Guide | Description |
|-------|-------------|
| **[Deployment Guide](docs/DEPLOYMENT.md)** | 🌟 All-in-one: Quick Start (30 min), Setup, Tag Deployment, Reference |
| **[Advanced Topics](docs/ADVANCED_TOPICS.md)** | Blue/Green, auto-scaling, monitoring, secrets management |
| **[Project Structure](docs/PROJECT_STRUCTURE.md)** | Architecture, deliverables, evaluation criteria, cost, security |

### Quick Links

- 🚀 **New user?** → [30-min Quick Start](docs/DEPLOYMENT.md#quick-start-30-minutes)
- 📦 **Deploying?** → [Tag-Based Deployment](docs/DEPLOYMENT.md#tag-based-deployment)
- 📝 **Need command?** → [Quick Reference](docs/DEPLOYMENT.md#deployment-quick-reference)
- 🔧 **Issues?** → [Troubleshooting](docs/DEPLOYMENT.md#troubleshooting)

## Architecture

```
Internet → ALB (Multi-AZ) → ECS Fargate (2 tasks) → CloudWatch
                                    ↓
                              ECR + SSM Parameters
```

**Stack**: Ruby 3.4.7 • Rails 7.1 API • Docker • AWS ECS • ALB • ECR • VPC • Terraform • GitHub Actions

## Tag-Based Deployment

```bash
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0
# GitHub Actions deploys automatically with semantic versioning
```

See [deployment guide](docs/DEPLOYMENT.md#tag-based-deployment) for rollbacks and best practices.

## Cost

~$100-120/month (us-east-1): NAT Gateway ($64) • ECS Fargate ($15) • ALB ($16) • Other ($6)

[Cost optimization →](docs/DEPLOYMENT.md#faq)