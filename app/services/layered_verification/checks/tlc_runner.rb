# frozen_string_literal: true

module LayeredVerification
  module Checks
    class TlcRunner
      # @spec LAYERED-VERIFY-022
      def self.call(...) = new(...).call

      def initialize(obligation:, model:, command_runner: nil, agent_run: nil)
        @obligation = obligation
        @model = model
        @command_runner = command_runner
        @agent_run = agent_run
      end

      def call
        return record_non_applicable("no declared TLA+ model") unless model
        return record_non_applicable("tlc command runner is unavailable") unless command_runner

        record_execution(command_runner.call(command))
      end

      private

      attr_reader :obligation, :model, :command_runner, :agent_run

      def command = [ "tlc", "-config", model.fetch(:config), "#{model.fetch(:module)}.tla" ]

      def record_execution(output)
        stdout = output.fetch(:stdout, "")
        state, coverage = outcome_for(stdout, output.fetch(:exitstatus))
        create_result(state:, coverage:, limitations: limitations_for(state), evidence_summary: { "stdout" => stdout, "command" => command })
      end

      def outcome_for(stdout, exitstatus)
        return [ "completed", "contradicted" ] if stdout.match?(/invariant violation/i)
        return [ "completed", "supported" ] if stdout.include?("Model checking completed.")

        [ "execution_error", "unresolved" ]
      end

      def limitations_for(state)
        state == "completed" ? "TLC result is bounded by the declared model and configuration" : "TLC did not produce a recognized completion result"
      end

      def record_non_applicable(reason)
        create_result(state: "non_applicable", coverage: "unresolved", limitations: reason)
      end

      def create_result(state:, coverage:, limitations:, evidence_summary: {})
        LayeredVerificationCheckResult.create!(
          obligation:, agent_run:, producer: "formal_verification", execution_state: state,
          obligation_coverage: coverage, input_revision: { "intent" => obligation.external_revision, "model" => model&.fetch(:revision, nil) },
          evidence_summary:, agent_reported: {}, recorder_verified: {}, cost: {}, limitations:
        )
      end
    end
  end
end
