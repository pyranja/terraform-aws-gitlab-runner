# terraform-aws-gitlab-runner/asg-termination-handler

Run instance cleanup scripts when an ASG instances is being terminated.
* adds a lifecycle hook to intercept instance terminations
* a cloudwatch event rule invokes a SSM automation document on termination notice
* SSM executes specified cleanup script and continues termination
