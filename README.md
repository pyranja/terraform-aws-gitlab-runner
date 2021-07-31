# terraform-aws-gitlab-runner

Deploy an [auto-scaled gitlab runner to EC2](https://docs.gitlab.com/runner/configuration/runner_autoscale_aws/).

## Quick Install

The root module deploys a single gitlab runner

## Shared Runner Cache

Deploy the nested `gitlab-runner-cache` module to create a S3 bucket that will be used as shared cache:

```
module "runner_cache" {
  source  = "hashicorp/gitlab-runner/aws//modules/gitlab-runner-cache"
  version = "1.0.0"

  TBD
}
```

Configure runner modules to use the shared cache:

```
module "my_runner" {
  source = "hashicorp/gitlab-runner/aws"
  version = "1.0.0"

  cache = module.runner_cache
}
```
