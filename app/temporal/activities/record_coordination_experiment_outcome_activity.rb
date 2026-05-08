# frozen_string_literal: true

module Activities
  class RecordCoordinationExperimentOutcomeActivity < BaseActivity
    activity_name "RecordCoordinationExperimentOutcome"

    def execute(input)
      assignment = CoordinationExperimentAssignment.find(input[:assignment_id])

      outcome = CoordinationExperiments::RecordOutcome.call(
        assignment: assignment,
        task_count: input[:task_count],
        parallel_execution: input[:parallel_execution],
        result: input[:result]
      )

      {
        assignment_id: assignment.id,
        coordination_score: outcome.coordination_score,
        outcome_status: assignment.reload.outcome_status
      }
    end
  end
end
