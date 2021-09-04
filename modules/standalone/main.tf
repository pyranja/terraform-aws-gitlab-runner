
# ----------------------------------------------------------------------------------------------------------------------
# global metadata
# ----------------------------------------------------------------------------------------------------------------------

terraform {
  required_version = ">= 0.12"
}

data "aws_region" "current" {}

locals {
  runner_name = "gl-${var.name}"

  tags = merge(
    { Name = local.runner_name, GitlabRunner = var.name },
    var.tags,
  )
}

# lookup full subnet information
data "aws_subnet" "runner_subnet" {
  id = var.subnet_id
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
  default_concurrent_jobs = data.aws_ec2_instance_type._.default_vcpus * 2
  max_concurrent_jobs     = coalesce(var.max_concurrent_jobs, local.default_concurrent_jobs)
}

# ----------------------------------------------------------------------------------------------------------------------
# The manager instance is run as an autoscaling group, that ensures that the instance stays up.
# ----------------------------------------------------------------------------------------------------------------------

resource "aws_autoscaling_group" "_" {
  name = local.runner_name

  # the group should keep the single runner instance running
  min_size         = 0
  max_size         = 1
  desired_capacity = 1

  vpc_zone_identifier = [data.aws_subnet.runner_subnet.id]

  health_check_type         = "EC2"
  health_check_grace_period = 0

  launch_template {
    id      = aws_launch_template._.id
    version = aws_launch_template._.latest_version
  }

  # rollout launch template changes automatically
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0
    }
  }

  enabled_metrics = [
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
  ]
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
      volume_type           = "gp2"
      volume_size           = var.autoscale.volume_size
      delete_on_termination = true
    }
  }

  user_data = base64encode(templatefile("${path.module}/template/cloud-config.yml", {
    name                = var.name
    gitlab_url          = var.gitlab.url
    gitlab_token        = var.gitlab.token
    region              = data.aws_region.current.name
    max_concurrent_jobs = local.max_concurrent_jobs
    cache_bucket        = var.cache.id
    cache_region        = var.cache.region
  }))

  vpc_security_group_ids = [aws_security_group._.id]

  iam_instance_profile {
    arn = aws_iam_instance_profile._.arn
  }

  metadata_options { # enforce IMDSv2
    http_endpoint               = "enabled"
    http_tokens                 = "optional"
    http_put_response_hop_limit = 1
  }

  credit_specification {
    cpu_credits = "standard" # disables default unlimited credit spec for t3+ instance types
  }
}

# ----------------------------------------------------------------------------------------------------------------------
# Pre-create a log group for the fluentd exporter running in the instances.
# ----------------------------------------------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "_" {
  name              = "/gitlab/runner/${var.name}"
  tags              = local.tags
  retention_in_days = 30
}

# ----------------------------------------------------------------------------------------------------------------------
# Allow egress to contact gitlab instance and arbitrary connections during builds.
# ----------------------------------------------------------------------------------------------------------------------

resource "aws_security_group" "_" {
  name_prefix = local.runner_name
  tags        = local.tags

  vpc_id = data.aws_subnet.runner_subnet.vpc_id

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "allow_outbound_all" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group._.id
}

# ----------------------------------------------------------------------------------------------------------------------
# The manager instance requires full access to EC2 for spawning runner VMs and access to the S3 bucket for caching
# ----------------------------------------------------------------------------------------------------------------------

resource "aws_iam_role" "_" {
  name_prefix = local.runner_name
  tags        = local.tags

  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json

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

resource "aws_iam_policy" "cache_access" {
  name_prefix = "${local.runner_name}-cache"
  tags        = local.tags
  policy      = data.aws_iam_policy_document.cache_access.json
}

data "aws_iam_policy_document" "cache_access" {
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
      var.cache.arn,        # access to put objects
      "${var.cache.arn}/*", # access to read/remove objects
    ]
  }
}

resource "aws_iam_role_policy_attachment" "cache_access" {
  role       = aws_iam_role._.id
  policy_arn = aws_iam_policy.cache_access.arn
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
