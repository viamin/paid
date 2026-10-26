# frozen_string_literal: true

module LayeredVerification
  module Checks
    # Parses output produced by the documented isolated `tlc` command. Command
    # execution stays with the existing agent/container execution boundary.
    # @spec LAYERED-VERIFY-022
    class TlcRunner
      def self.result_for(stdout:, exit_status:, evidence_ref: nil)
        if stdout.include?("Model checking completed.")
          { execution_state: "completed", obligation_coverage: "supported", evidence_ref:, limitations: "TLC checks only the declared model and bounds." }
        elsif stdout.match?(/invariant.+violated/i)
          { execution_state: "completed", obligation_coverage: "contradicted", evidence_ref:, limitations: "Counterexample applies only to the declared model and bounds." }
        else
          { execution_state: "execution_error", obligation_coverage: "unresolved", evidence_ref:, limitations: "tlc exited #{exit_status} without a recognized result." }
        end
      end

      def self.non_applicable(reason:)
        { execution_state: "non_applicable", obligation_coverage: "unresolved", evidence_ref: nil, limitations: reason }
      end
    end
  end
end
