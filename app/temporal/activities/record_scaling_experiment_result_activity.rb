# frozen_string_literal: true

module Activities
  class RecordScalingExperimentResultActivity < BaseActivity
    activity_name "RecordScalingExperimentResult"

    def execute(input)
      assignment = ScalingExperimentAssignment.find(input[:assignment_id])
      scaling_observation = ScalingObservation.find(input[:scaling_observation_id])

      result = ScalingExperiments::RecordResult.call(
        assignment: assignment,
        scaling_observation: scaling_observation
      )

      {
        assignment_id: assignment.id,
        outcome_status: assignment.reload.outcome_status,
        summary_status: result.summary["status"]
      }
    end
  end
end
