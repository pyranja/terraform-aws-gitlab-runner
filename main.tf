
# ----------------------------------------------------------------------------------------------------------------------
# global metadata
# ----------------------------------------------------------------------------------------------------------------------

terraform {
  required_version = ">= 0.12"
}

data "aws_region" "current" {}

locals {
  manager_instance_name = "gl-${var.name}"

  tags = merge(
  { Name = local.manager_instance_name },
  var.custom_tags,
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

# ----------------------------------------------------------------------------------------------------------------------
# The manager instance is run as an autoscaling group, that ensures that the instance stays up.
# ----------------------------------------------------------------------------------------------------------------------

resource "aws_autoscaling_group" "_" {
  name = local.manager_instance_name

  # the group should keep the single manager instance running
  min_size         = 0
  max_size         = 1
  desired_capacity = 1

  vpc_zone_identifier = [data.aws_subnet.runner_subnet.id]

  health_check_type         = "EC2"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template._.id
    version = "$Latest"
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
  name_prefix = local.manager_instance_name
  tags        = local.tags

  tag_specifications {
    resource_type = "instance"
    tags          = local.tags
  }

  update_default_version = true

  image_id      = coalesce(var.manager_ami_id, data.aws_ami.amzn_linux_2.id)
  instance_type = var.manager_instance_type

  user_data = base64encode(templatefile("${path.module}/template/cloud-config.yml", {
    name          = var.name
    gitlab_url    = var.gitlab.url
    gitlab_token  = var.gitlab.token
    region        = data.aws_region.current.name
    vpc_id        = data.aws_subnet.runner_subnet.vpc_id
    subnet_id     = data.aws_subnet.runner_subnet.id
    zone          = trimprefix(data.aws_subnet.runner_subnet.availability_zone, data.aws_region.current.name)
    instance_type = var.autoscale.instance_type
    min_worker    = var.autoscale.min_worker
    max_worker    = var.autoscale.max_worker
  }))

  vpc_security_group_ids = [aws_security_group._.id]

  iam_instance_profile {
    arn = aws_iam_instance_profile._.arn
  }

  metadata_options { # enforce IMDSv2
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  credit_specification {
    cpu_credits = "standard" # disables default unlimited credit spec for t3+ instance types
  }
}

# ----------------------------------------------------------------------------------------------------------------------
# The manager instance must be able to contact spawned runner VMs and the gitlab host to poll for jobs.
# ----------------------------------------------------------------------------------------------------------------------

resource "aws_security_group" "_" {
  name_prefix = local.manager_instance_name
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
  name_prefix = local.manager_instance_name
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

# managed policy that grants full access to EC2 to let the manager instance spawn new build VMs
data "aws_iam_policy" "ec2_full_access" {
  arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
}

resource "aws_iam_role_policy_attachment" "ec2_full_access" {
  role       = aws_iam_role._.id
  policy_arn = data.aws_iam_policy.ec2_full_access.arn
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
  name_prefix = local.manager_instance_name
  role        = aws_iam_role._.name

  lifecycle {
    create_before_destroy = true
  }

  # AWS IAM is eventually consistent - entities are not immediately usable
  provisioner "local-exec" {
    command = "echo 'waiting 15s for IAM propagation'; sleep 15"
  }
}
