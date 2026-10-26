# frozen_string_literal: true

module LayeredVerification
  module Checks
    # Parses the documented TLC command result emitted by the isolated runner.
    # Command execution remains in agent-harness, never in the Rails process.
    # @spec LAYERED-VERIFY-022
    class TlcRunner
      Result = Data.define(:command, :execution_state, :obligation_coverage, :limitations, :evidence)

      def self.call(...) = new(...).call

      def initialize(module_path:, config_path:, tlc_available:, exit_status:, output:)
        @module_path = module_path.to_s
        @config_path = config_path.to_s
        @tlc_available = tlc_available
        @exit_status = exit_status
        @output = output.to_s
      end

      def call
        return not_applicable("No TLA+ model was declared for this audit.") if module_path.blank? || config_path.blank?
        return not_applicable("The declared TLA+ model cannot run because tlc is unavailable.") unless tlc_available
        return supported if output.include?("Model checking completed.")
        return contradicted if invariant_violation?

        Result.new(command:, execution_state: "execution_error", obligation_coverage: "unresolved", limitations: "TLC exited without a recognized result.", evidence: { "output" => output })
      end

      private

      attr_reader :module_path, :config_path, :tlc_available, :exit_status, :output

      def command = "tlc -config #{config_path} #{module_path}"

      def not_applicable(limitations)
        Result.new(command: nil, execution_state: "non_applicable", obligation_coverage: "unresolved", limitations:, evidence: {})
      end

      def supported
        Result.new(command:, execution_state: "completed", obligation_coverage: "supported", limitations: "TLC checks only the declared model and configured bounds.", evidence: { "output" => output })
      end

      def contradicted
        Result.new(command:, execution_state: "completed", obligation_coverage: "contradicted", limitations: "Counterexample applies only to the declared model and bounds.", evidence: { "counterexample" => output })
      end

      def invariant_violation?
        exit_status.to_i != 0 && output.match?(/invariant .* is violated|error: invariant/i)
      end
    end
  end
end
