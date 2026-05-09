# frozen_string_literal: true

module Activities
  class ResolveScalingExperimentActivity < BaseActivity
    activity_name "ResolveScalingExperiment"

    def execute(input)
      project = Project.find(input[:project_id])
      workflow_id = input[:workflow_id].to_s
      task_count = input[:task_count].to_i
      issue = input[:issue_id] ? project.issues.find(input[:issue_id]) : nil

      experiment = ScalingExperiment.active_for(
        project: project,
        dimension: "agent_count",
        workflow_id: workflow_id,
        task_count: task_count
      )
      return { assignment_id: nil, execution_plan: nil } unless experiment

      assignment = ScalingExperiments::Assign.call(
        scaling_experiment: experiment,
        project: project,
        issue: issue,
        workflow_id: workflow_id,
        task_count: task_count
      )
      return { assignment_id: nil, execution_plan: nil } unless assignment

      {
        assignment_id: assignment.id,
        scaling_experiment_id: experiment.id,
        assigned_value: assignment.assigned_value,
        execution_plan: assignment.execution_plan
      }
    end
  end
end
