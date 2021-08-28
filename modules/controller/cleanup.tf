# ----------------------------------------------------------------------------------------------------------------------
# On termination the controller must clean up, e.g. remove worker instances
# ASG termination -> cloudwatch event -> invoke ssm run document -> execute shell script -> continue ASG termination
# ----------------------------------------------------------------------------------------------------------------------

resource "aws_autoscaling_lifecycle_hook" "cleanup" {
  name                   = "cleanup"
  autoscaling_group_name = aws_autoscaling_group._.name
  default_result         = "CONTINUE"
  heartbeat_timeout      = "300" # seconds
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_TERMINATING"
}

# SSM automation document that runs the cleanup script on the runner
resource "aws_ssm_document" "cleanup_automation" {
  name = "${local.manager_instance_name}-cleanup-automation"
  tags = local.tags

  document_type   = "Automation"
  document_format = "YAML"
  content         = <<EOF
description: 'Run a cleanup script on a terminating gitlab runner.'
schemaVersion: '0.3'
assumeRole: '${aws_iam_role.cleanup_automation.arn}'
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
    inputs:
      DocumentName: AWS-RunShellScript
      TimeoutSeconds: 60
      InstanceIds:
        - '{{ EC2InstanceId }}'
      Parameters:
        executionTimeout: '300'
        commands:
          - '/bin/cleanup-runner.sh'
      CloudWatchOutputConfig:
        CloudWatchLogGroupName: '${aws_cloudwatch_log_group.cleanup_log.name}'
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
resource "aws_iam_role" "cleanup_automation" {
  name_prefix        = "gl-cleanup-automation-"
  tags               = local.tags
  assume_role_policy = data.aws_iam_policy_document.cleanup_automation_assume.json
}

data "aws_iam_policy_document" "cleanup_automation_assume" {
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

resource "aws_iam_role_policy_attachment" "cleanup_automation" {
  role       = aws_iam_role.cleanup_automation.id
  policy_arn = aws_iam_policy.cleanup_automation.arn
}

resource "aws_iam_policy" "cleanup_automation" {
  name_prefix = "gl-cleanup-automation-"
  policy      = data.aws_iam_policy_document.cleanup_automation.json
}

data "aws_iam_policy_document" "cleanup_automation" {
  statement {
    sid    = "CompleteAsgLifecycle"
    effect = "Allow"
    actions = [
      "autoscaling:CompleteLifecycleAction"
    ]
    resources = [
      aws_autoscaling_group._.arn
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
resource "aws_cloudwatch_event_rule" "cleanup" {
  name_prefix = "gl-cleanup-"
  description = "Trigger the cleanup automation document when the gitlab runner instance is terminated."
  tags        = local.tags

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
    "${aws_autoscaling_group._.arn}"
  ]
}
  EOF
}

resource "aws_cloudwatch_log_group" "cleanup_log" {
  name              = "/aws/events/${local.manager_instance_name}-cleanup"
  tags              = local.tags
  retention_in_days = 30
}

# save trigger events for debugging
resource "aws_cloudwatch_event_target" "cleanup_log" {
  rule = aws_cloudwatch_event_rule.cleanup.name
  arn  = aws_cloudwatch_log_group.cleanup_log.arn
}

resource "aws_cloudwatch_event_target" "cleanup" {
  rule     = aws_cloudwatch_event_rule.cleanup.name
  role_arn = aws_iam_role.cleanup_event.arn
  # see https://github.com/hashicorp/terraform-provider-aws/issues/6461#issuecomment-510845647
  arn = replace(aws_ssm_document.cleanup_automation.arn, "document/", "automation-definition/")

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
resource "aws_iam_role" "cleanup_event" {
  name_prefix        = "gl-cleanup-event-"
  tags               = local.tags
  assume_role_policy = data.aws_iam_policy_document.cleanup_event_assume.json
}

data "aws_iam_policy_document" "cleanup_event_assume" {
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

resource "aws_iam_role_policy_attachment" "cleanup_event" {
  role       = aws_iam_role.cleanup_event.id
  policy_arn = aws_iam_policy.cleanup_event.arn
}

resource "aws_iam_policy" "cleanup_event" {
  name_prefix = "gl-cleanup-event-"
  policy      = data.aws_iam_policy_document.cleanup_event.json
}

data "aws_iam_policy_document" "cleanup_event" {
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
      "${replace(aws_ssm_document.cleanup_automation.arn, "document/", "automation-definition/")}:$DEFAULT"
    ]
  }
  statement {
    sid    = "PassSsmRole"
    effect = "Allow"
    actions = [
      "iam:PassRole"
    ]
    resources = [
      aws_iam_role.cleanup_automation.arn
    ]
  }
}
