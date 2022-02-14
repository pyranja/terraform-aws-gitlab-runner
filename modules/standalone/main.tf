
# ----------------------------------------------------------------------------------------------------------------------
# global metadata
# ----------------------------------------------------------------------------------------------------------------------

terraform {
  required_version = ">= 0.14"
}

data "aws_region" "current" {}

locals {
  runner_name = "gl-${var.name}"

  tags = merge(
    { Name = local.runner_name, GitlabRunner = var.name },
    var.tags,
  )

  subnets = compact(flatten([var.subnet_id, var.subnets]))
}

# lookup full subnet information
data "aws_subnet" "runner_subnet" {
  id = local.subnets[0]
}

# by default use the latest Amazon Linux 2 AMI
data "aws_ami" "amzn_linux_2" {
  owners      = ["amazon"]
  most_recent = true

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-ebs"]
  }
}

# get instance characteristics to derive config options
data "aws_ec2_instance_type" "_" {
  instance_type = var.autoscale.instance_type
}

locals {
  # calculate concurrent jobs - 2 jobs per available vcpu
  default_concurrent_jobs = data.aws_ec2_instance_type._.default_vcpus * var.concurrency_factor
  max_concurrent_jobs     = coalesce(var.max_concurrent_jobs, local.default_concurrent_jobs)
}

# ----------------------------------------------------------------------------------------------------------------------
# The manager instance is run as an autoscaling group, that ensures that the instance stays up.
# ----------------------------------------------------------------------------------------------------------------------

resource "aws_autoscaling_group" "_" {
  name = local.runner_name

  # the group should keep the single runner instance running
  min_size         = var.autoscale.min_worker
  max_size         = var.autoscale.max_worker
  desired_capacity = var.autoscale.max_worker

  # recycle runner instances every day
  max_instance_lifetime = 60 * 60 * 24

  vpc_zone_identifier = local.subnets

  health_check_type         = "EC2"
  health_check_grace_period = 0

  dynamic "tag" {
    for_each = local.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  # request spot instances
  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template._.id
        version            = aws_launch_template._.latest_version
      }
    }
    instances_distribution {
      on_demand_base_capacity                  = 1 # ensure at least one runner is always up
      on_demand_percentage_above_base_capacity = 0 # request only spot instances
    }
  }

  # preempts spot terminations
  capacity_rebalance = true

  # rollout launch template changes automatically
  instance_refresh {
    strategy = "Rolling"
    preferences { # keep some runners around during upgrades
      min_healthy_percentage = 90
    }
  }

  enabled_metrics = [
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
  ]

  depends_on = [aws_launch_template._]
}

resource "aws_autoscaling_schedule" "night" {
  scheduled_action_name  = "scale_down_at_night"
  autoscaling_group_name = aws_autoscaling_group._.name

  recurrence = "0 19 * * 1-5" # ~ 20:00 CET

  min_size         = var.autoscale.min_worker
  max_size         = var.autoscale.max_worker
  desired_capacity = var.autoscale.min_worker
}

resource "aws_autoscaling_schedule" "day" {
  scheduled_action_name  = "scale_up_day"
  autoscaling_group_name = aws_autoscaling_group._.name

  recurrence = "0 7 * * 1-5" # ~ 08:00 CET

  min_size         = var.autoscale.min_worker
  max_size         = var.autoscale.max_worker
  desired_capacity = var.autoscale.max_worker
}

resource "aws_launch_template" "_" {
  name_prefix = local.runner_name
  tags        = local.tags

  tag_specifications {
    resource_type = "instance"
    tags          = local.tags
  }

  update_default_version = true

  image_id      = coalesce(var.ami_id, data.aws_ami.amzn_linux_2.id)
  instance_type = var.autoscale.instance_type

  # increase root volume size
  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      volume_size           = var.autoscale.volume_size
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/template/cloud-config.yml", {
    runner_name         = var.name
    runner_tags         = join(",", var.gitlab.tags)
    gitlab_url          = var.gitlab.url
    token_secret        = var.gitlab_token.arn
    region              = data.aws_region.current.name
    max_concurrent_jobs = local.max_concurrent_jobs
    shared_cache        = var.cache != null
    cache_bucket        = var.cache == null ? "" : var.cache.id
    cache_region        = var.cache == null ? "" : var.cache.region
    # docker customization
    docker_default_cidr = var.docker_default_cidr
  }))

  vpc_security_group_ids = [aws_security_group._.id]

  iam_instance_profile {
    arn = aws_iam_instance_profile._.arn
  }

  #checkov:skip=CKV_AWS_79:log export does not support IMDSv2
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 1
  }

  credit_specification {
    cpu_credits = "standard" # disables default unlimited credit spec for t3+ instance types
  }
}

# ----------------------------------------------------------------------------------------------------------------------
# Unregister the runner before termination
# ----------------------------------------------------------------------------------------------------------------------

module "termination" {
  source = "../asg-termination-handler"

  name              = local.runner_name
  tags              = local.tags
  autoscaling_group = aws_autoscaling_group._
}

# ----------------------------------------------------------------------------------------------------------------------
# Pre-create a log group for the fluentd exporter running in the instances.
# ----------------------------------------------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "_" {
  #checkov:skip=CKV_AWS_158:AWS default encryption sufficient
  name              = "/gitlab/runner/${var.name}"
  tags              = local.tags
  retention_in_days = 30
}

# ----------------------------------------------------------------------------------------------------------------------
# Allow egress to contact gitlab instance and arbitrary connections during builds.
# ----------------------------------------------------------------------------------------------------------------------

resource "aws_security_group" "_" {
  #checkov:skip=CKV_AWS_23:false positive - no inline rules
  name_prefix = local.runner_name
  tags        = local.tags

  vpc_id = data.aws_subnet.runner_subnet.vpc_id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "allow_outbound_all" {
  description       = "allow egress"
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group._.id
}

# ----------------------------------------------------------------------------------------------------------------------
# The runner instance requires access to the S3 bucket for caching.
# ----------------------------------------------------------------------------------------------------------------------

resource "aws_iam_role" "_" {
  name_prefix = local.runner_name
  tags        = local.tags

  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json

  permissions_boundary = var.permissions_boundary

  lifecycle {
    create_before_destroy = true
  }

  # AWS IAM is eventually consistent - entities are not immediately usable
  provisioner "local-exec" {
    command = "echo 'waiting 15s for IAM propagation'; sleep 15"
  }
}

# managed policy that grants local ssm agent permissions to manage the instance
# amzn linux 2 bundles the ssm agent and with appropriate IAM permission it will auto-activate
data "aws_iam_policy" "ssm" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2RoleforSSM"
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role._.id
  policy_arn = data.aws_iam_policy.ssm.arn
}

# managed policy that grants permission to push logs and metrics to cloudwatch
# re-purposing the cloudwatch agent permissions for the journald export via fluentbit
data "aws_iam_policy" "cloudwatch" {
  arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role._.id
  policy_arn = data.aws_iam_policy.cloudwatch.arn
}

# dynamically included policy for S3 cache access
# dependent policy and policy attachment resources use for_each
data "aws_iam_policy_document" "cache_access" {
  for_each = var.cache == null ? {} : { enabled : var.cache.arn }

  statement {
    sid    = "GitlabCache"
    effect = "Allow"
    actions = [
      "s3:PutObject",
      "s3:GetObjectVersion",
      "s3:GetObject",
      "s3:DeleteObject",
    ]

    resources = [
      each.value,        # access to put objects
      "${each.value}/*", # access to read/remove objects
    ]
  }
}

resource "aws_iam_policy" "cache_access" {
  for_each = data.aws_iam_policy_document.cache_access

  name_prefix = "${local.runner_name}-cache"
  tags        = local.tags
  policy      = each.value.json
}

resource "aws_iam_role_policy_attachment" "cache_access" {
  for_each = aws_iam_policy.cache_access

  role       = aws_iam_role._.id
  policy_arn = each.value.arn
}

resource "aws_iam_policy" "token_access" {
  name_prefix = "${local.runner_name}-token"
  tags        = local.tags
  policy      = data.aws_iam_policy_document.token_access.json
}

data "aws_iam_policy_document" "token_access" {
  statement {
    sid    = "GitlabToken"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
    ]

    resources = [
      var.gitlab_token.arn
    ]
  }
}

resource "aws_iam_role_policy_attachment" "token_access" {
  role       = aws_iam_role._.id
  policy_arn = aws_iam_policy.token_access.arn
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_instance_profile" "_" {
  name_prefix = local.runner_name
  role        = aws_iam_role._.name

  lifecycle {
    create_before_destroy = true
  }

  # AWS IAM is eventually consistent - entities are not immediately usable
  provisioner "local-exec" {
    command = "echo 'waiting 15s for IAM propagation'; sleep 15"
  }
}
