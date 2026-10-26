# frozen_string_literal: true

module LayeredVerification
  module Checks
    class TlcRunner
      # @spec LAYERED-VERIFY-022
      def self.call(...) = new(...).call

      def initialize(obligation:, agent_run:, model:, executor: nil)
        @obligation = obligation
        @agent_run = agent_run
        @model = model&.deep_stringify_keys
        @executor = executor
      end

      def call
        return record_non_applicable("No TLA+ model is declared for this audit.") if model.blank?
        return record_non_applicable("The declared TLA+ module/config pair is incomplete.") unless model.values_at("module", "config").all?(&:present?)
        return record_non_applicable("The isolated executor does not provide tlc.") unless executor

        record_execution(executor.call(command))
      end

      private

      attr_reader :agent_run, :executor, :model, :obligation

      def command
        "tlc -config #{model.fetch("config")} #{model.fetch("module")}"
      end

      def record_execution(output)
        text = output.fetch(:stdout, "").to_s
        violation = text.match?(/invariant.*violat|counterexample/i)
        completed = text.include?("Model checking completed.") || violation
        state = completed ? "completed" : "execution_error"
        coverage = violation ? "contradicted" : (completed ? "supported" : "unresolved")
        record(state:, coverage:, limitations: completed ? "TLC checks only the declared model and configuration." : "TLC did not report a completed model check.", summary: { "command" => command, "exit_status" => output[:exit_status] })
      end

      def record_non_applicable(limitations)
        record(state: "non_applicable", coverage: "unresolved", limitations:, summary: {})
      end

      def record(state:, coverage:, limitations:, summary:)
        LayeredVerificationCheckResult.create!(
          obligation:, agent_run:, producer: "formal_verification", execution_state: state,
          obligation_coverage: coverage, input_revision: { "external_revision" => obligation.external_revision },
          evidence_summary: summary, recorder_verified: summary, limitations:
        )
      end
    end
  end
end
