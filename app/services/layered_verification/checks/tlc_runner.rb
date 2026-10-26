# frozen_string_literal: true

module LayeredVerification
  module Checks
    class TlcRunner
      # @spec LAYERED-VERIFY-022
      Result = Data.define(:execution_state, :obligation_coverage, :evidence_ref, :limitations, :recorder_verified)

      def self.call(...) = new(...).call

      def initialize(module_path:, config_path:, command_runner:, evidence_store: nil)
        @module_path = module_path
        @config_path = config_path
        @command_runner = command_runner
        @evidence_store = evidence_store
      end

      def call
        return non_applicable("No TLA+ model/configuration pair was declared") unless module_path.present? && config_path.present?

        outcome = command_runner.call("tlc -config #{config_path} #{module_path}")
        output = outcome.fetch(:output, "").to_s
        return completed(output) if output.include?("Model checking completed.")
        return contradicted(output) if invariant_violation?(output)

        Result.new(execution_state: "execution_error", obligation_coverage: "unresolved", evidence_ref: store(output), limitations: "TLC exited without a recognized result", recorder_verified: { "exit_status" => outcome[:exit_status] })
      rescue Errno::ENOENT
        non_applicable("The tlc command is not available in the isolated execution environment")
      end

      private

      attr_reader :command_runner, :config_path, :evidence_store, :module_path

      def completed(output)
        Result.new(execution_state: "completed", obligation_coverage: "supported", evidence_ref: store(output), limitations: "TLC checks only the declared model and configured bounds", recorder_verified: { "parsed" => "completed" })
      end

      def contradicted(output)
        Result.new(execution_state: "completed", obligation_coverage: "contradicted", evidence_ref: store(output), limitations: "Counterexample applies to the declared model and configured bounds", recorder_verified: { "parsed" => "invariant_violation" })
      end

      def non_applicable(reason)
        Result.new(execution_state: "non_applicable", obligation_coverage: "unresolved", evidence_ref: nil, limitations: reason, recorder_verified: {})
      end

      def invariant_violation?(output)
        output.match?(/invariant.*violat|error:\s+invariant/i)
      end

      def store(output)
        evidence_store&.call(output)
      end
    end
  end
end
