# frozen_string_literal: true

module Activities
  class RecordScalingObservationActivity < BaseActivity
    activity_name "RecordScalingObservation"

    def execute(input)
      observation = ScalingObservations::Record.call(**input.deep_symbolize_keys)

      {
        scaling_observation_id: observation.id,
        workflow_id: observation.workflow_id
      }
    end
  end
end
