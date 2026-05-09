# frozen_string_literal: true

module Activities
  class ResolveScalingExperimentActivity < BaseActivity
    activity_name "ResolveScalingExperiment"

    def execute(input)
      project = Project.find(input[:project_id])
      workflow_id = input[:workflow_id].to_s
      task_count = input[:task_count].to_i
      issue = input[:issue_id] ? project.issues.find(input[:issue_id]) : nil

      assignments = ScalingExperiment.running
        .where(project: project)
        .order(:id)
        .filter_map do |experiment|
        next unless experiment.includes_traffic?(workflow_id:)
        next unless experiment.matches_context?(task_count:)

        assignment = ScalingExperiments::Assign.call(
          scaling_experiment: experiment,
          project: project,
          issue: issue,
          workflow_id: workflow_id,
          task_count: task_count
        )
        next unless assignment

        {
          assignment_id: assignment.id,
          scaling_experiment_id: experiment.id,
          dimension: experiment.dimension,
          assigned_value: assignment.assigned_value,
          execution_plan: assignment.execution_plan
        }
      end

      {
        assignment_ids: assignments.map { |assignment| assignment[:assignment_id] },
        assignments: assignments
      }
    end
  end
end
