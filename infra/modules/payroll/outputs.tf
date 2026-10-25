output "state_machine_arn" {
  description = "Payroll state machine ARN."
  value       = aws_sfn_state_machine.payroll.arn
}

output "state_machine_name" {
  description = "Payroll state machine name."
  value       = aws_sfn_state_machine.payroll.name
}

output "task_function_names" {
  description = "Payroll task Lambda names."
  value       = { for k, m in module.task : k => m.name }
}
