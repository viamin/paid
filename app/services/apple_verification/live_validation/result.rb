# frozen_string_literal: true

module AppleVerification
  module LiveValidation
    # Aggregate outcome of one harness run.
    # @spec APPLE-LIVE-002
    Result = Data.define(:started_at, :finished_at, :repeats, :environment, :evidence) do
      def evidence_for(scenario_id)
        evidence.select { |row| row.scenario_id == scenario_id }
      end

      def rows_for(scenario_ids)
        scenario_ids.flat_map { |scenario_id| evidence_for(scenario_id) }
      end
    end
  end
end
