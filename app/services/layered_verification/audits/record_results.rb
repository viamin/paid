# frozen_string_literal: true

module LayeredVerification
  module Audits
    # Retains evidence and coverage independently of execution success.
    # @spec LAYERED-VERIFY-008 LAYERED-VERIFY-024
    class RecordResults
      def self.call(agent_run:)
        IngestResults.call(agent_run:)
        coverage = SynthesizeCoverage.call(agent_run:).transform_keys { |obligation| obligation.id.to_s }
        agent_run.with_lock do
          metadata = agent_run.external_metadata.deep_dup
          metadata.fetch("layered_verification")["coverage"] = coverage
          agent_run.update!(external_metadata: metadata)
        end
        coverage
      end
    end
  end
end
