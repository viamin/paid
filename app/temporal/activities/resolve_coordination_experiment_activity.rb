# frozen_string_literal: true

module Activities
  class ResolveCoordinationExperimentActivity < BaseActivity
    activity_name "ResolveCoordinationExperiment"

    def execute(input)
      project = Project.find(input[:project_id])
      workflow_id = input[:workflow_id].to_s
      issue = input[:issue_id] ? project.issues.find(input[:issue_id]) : nil

      experiment = CoordinationExperiment.active_for(account: project.account, workflow_id:)
      return { assignment_id: nil, coordination_policy: nil } unless experiment

      assignment = CoordinationExperiments::Assign.call(
        coordination_experiment: experiment,
        project: project,
        issue: issue,
        workflow_id:
      )

      {
        assignment_id: assignment.id,
        experiment_id: experiment.id,
        variant_id: assignment.coordination_experiment_variant_id,
        coordination_policy: assignment.coordination_experiment_variant.parsed_policy
      }
    end
  end
end
