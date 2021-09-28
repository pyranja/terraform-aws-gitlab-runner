
# ----------------------------------------------------------------------------------------------------------------------
# global metadata
# ----------------------------------------------------------------------------------------------------------------------

terraform {
  required_version = ">= 0.12"
}

# ----------------------------------------------------------------------------------------------------------------------
# lifecycle hook to interrupt instance termination
# ----------------------------------------------------------------------------------------------------------------------

resource "aws_autoscaling_lifecycle_hook" "_" {
  name                   = "termination-handler"
  autoscaling_group_name = var.autoscaling_group.name
  default_result         = "CONTINUE"
  heartbeat_timeout      = "300" # seconds
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_TERMINATING"
}

# SSM automation document that runs the cleanup script on the runner
resource "aws_ssm_document" "_" {
  name = "${var.name}-termination-handler"
  tags = var.tags

  document_type   = "Automation"
  document_format = "YAML"
  content         = <<EOF
description: 'Run a cleanup script on a terminating gitlab runner.'
schemaVersion: '0.3'
assumeRole: '${aws_iam_role.automation.arn}'
parameters:
  EC2InstanceId:
    type: String
  AutoScalingGroupName:
    type: String
  LifecycleHookName:
    type: String
  LifecycleActionToken:
    type: String
mainSteps:
  - name: 'RunCleanupScript'
    action: 'aws:runCommand'
    timeoutSeconds: 60
    onFailure: 'Continue'
    isCritical: true
    inputs:
      DocumentName: AWS-RunShellScript
      TimeoutSeconds: 60
      InstanceIds:
        - '{{ EC2InstanceId }}'
      Parameters:
        executionTimeout: '300'
        commands:
          - '${var.cleanup_script_path}'
      CloudWatchOutputConfig:
        CloudWatchLogGroupName: '${aws_cloudwatch_log_group._.name}'
        CloudWatchOutputEnabled: true
  - name: 'ContinueTermination'
    action: 'aws:executeAwsApi'
    inputs:
      Service: 'autoscaling'
      Api: 'CompleteLifecycleAction'
      AutoScalingGroupName: '{{ AutoScalingGroupName }}'
      InstanceId: '{{ EC2InstanceId }}'
      LifecycleActionResult: 'CONTINUE'
      LifecycleHookName: '{{ LifecycleHookName }}'
      LifecycleActionToken: '{{ LifecycleActionToken }}'
EOF
}

# role is used by the automation document
resource "aws_iam_role" "automation" {
  name_prefix        = "termination-handler-"
  tags               = var.tags
  assume_role_policy = data.aws_iam_policy_document.automation_assume.json

  permissions_boundary = var.permissions_boundary
}

data "aws_iam_policy_document" "automation_assume" {
  statement {
    sid    = "TrustSsm"
    effect = "Allow"
    actions = [
      "sts:AssumeRole"
    ]
    principals {
      type        = "Service"
      identifiers = ["ssm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "automation" {
  role       = aws_iam_role.automation.id
  policy_arn = aws_iam_policy.automation.arn
}

resource "aws_iam_policy" "automation" {
  name_prefix = "termination-handler-"
  policy      = data.aws_iam_policy_document.automation.json
}

data "aws_iam_policy_document" "automation" {
  statement {
    sid    = "CompleteAsgLifecycle"
    effect = "Allow"
    actions = [
      "autoscaling:CompleteLifecycleAction"
    ]
    resources = [
      var.autoscaling_group.arn
    ]
  }
  statement {
    sid    = "SsmMetadata"
    effect = "Allow"
    actions = [
      "ssm:DescribeInstanceInformation",
      "ssm:ListCommands",
      "ssm:ListCommandInvocations",
    ]
    resources = [
      "*"
    ]
  }
  statement {
    sid    = "SsmSendCommandDocument"
    effect = "Allow"
    actions = [
      "ssm:SendCommand",
    ]
    resources = [
      "arn:aws:ssm:*::document/AWS-RunShellScript"
    ]
  }
  statement {
    sid    = "SsmSendCommandInstance"
    effect = "Allow"
    actions = [
      "ssm:SendCommand",
    ]
    resources = [
      "arn:aws:ec2:*:*:instance/*"
    ]
  }
}

# cloudwatch event rule monitors termination events
resource "aws_cloudwatch_event_rule" "_" {
  name_prefix = "termination-handler-"
  description = "Triggers an automation document when an ASG instance is terminated."
  tags        = var.tags

  # match termination events from the runner auto scaling group
  event_pattern = <<EOF
{
  "source": [
    "aws.autoscaling"
  ],
  "detail-type": [
    "EC2 Instance-terminate Lifecycle Action"
  ],
  "resources" : [
    "${var.autoscaling_group.arn}"
  ]
}
  EOF
}

resource "aws_cloudwatch_log_group" "_" {
  name              = "/aws/events/${var.name}-termination-handler"
  tags              = var.tags
  retention_in_days = 30
}

# save trigger events for debugging
resource "aws_cloudwatch_event_target" "log_events" {
  rule = aws_cloudwatch_event_rule._.name
  arn  = aws_cloudwatch_log_group._.arn
}

resource "aws_cloudwatch_event_target" "automation" {
  rule     = aws_cloudwatch_event_rule._.name
  role_arn = aws_iam_role.automation_event_target.arn
  # see https://github.com/hashicorp/terraform-provider-aws/issues/6461#issuecomment-510845647
  arn = replace(aws_ssm_document._.arn, "document/", "automation-definition/")

  # forward the EC2 instance from the event payload to the SSM document
  input_transformer {
    input_paths = {
      "EC2InstanceId"        = "$.detail.EC2InstanceId"
      "AutoScalingGroupName" = "$.detail.AutoScalingGroupName"
      "LifecycleHookName"    = "$.detail.LifecycleHookName"
      "LifecycleActionToken" = "$.detail.LifecycleActionToken"
    }
    # send-command expects to receive parameters as json arrays
    # <..> placeholder are replaced with input paths
    # https://docs.aws.amazon.com/cli/latest/reference/ssm/send-command.html
    input_template = <<EOF
{
  "EC2InstanceId": [<EC2InstanceId>],
  "AutoScalingGroupName": [<AutoScalingGroupName>],
  "LifecycleHookName": [<LifecycleHookName>],
  "LifecycleActionToken": [<LifecycleActionToken>]
}
EOF
  }
}

# role is used by the cloudwatch event target to invoke the SSM document
resource "aws_iam_role" "automation_event_target" {
  name_prefix        = "termination-handler-"
  tags               = var.tags
  assume_role_policy = data.aws_iam_policy_document.automation_event_target_assume.json

  permissions_boundary = var.permissions_boundary
}

data "aws_iam_policy_document" "automation_event_target_assume" {
  statement {
    sid    = "TrustCloudwatchEvents"
    effect = "Allow"
    actions = [
      "sts:AssumeRole"
    ]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "automation_event_target" {
  role       = aws_iam_role.automation_event_target.id
  policy_arn = aws_iam_policy.automation_event_target.arn
}

resource "aws_iam_policy" "automation_event_target" {
  name_prefix = "termination-handler-event-"
  policy      = data.aws_iam_policy_document.automation_event_target.json
}

data "aws_iam_policy_document" "automation_event_target" {
  statement {
    sid    = "SsmAutomation"
    effect = "Allow"
    actions = [
      "ssm:StartAutomationExecution"
    ]
    resources = [
      # ssm documents must be referenced incl. the document revision
      # cloudwatch events reference `automation-definition` instead of `document` in the ARN
      # see https://github.com/hashicorp/terraform-provider-aws/issues/6461#issuecomment-510845647
      "${replace(aws_ssm_document._.arn, "document/", "automation-definition/")}:$DEFAULT"
    ]
  }
  statement {
    sid    = "PassSsmRole"
    effect = "Allow"
    actions = [
      "iam:PassRole"
    ]
    resources = [
      aws_iam_role.automation.arn
    ]
  }
}
