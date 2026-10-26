# frozen_string_literal: true

module LayeredVerification
  module Checks
    class TlcRunner
      # @spec LAYERED-VERIFY-022
      def self.call(...) = new(...).call

      def initialize(obligation:, module_path:, config_path:, agent_run: nil, command_runner: nil)
        @obligation = obligation
        @module_path = module_path
        @config_path = config_path
        @agent_run = agent_run
        @command_runner = command_runner
      end

      def call
        return non_applicable("No TLA+ model was declared for this audit scope.") unless declared_model?
        return non_applicable("The declared TLA+ module/config pair is unavailable.") unless command_runner

        record(command_result)
      end

      private

      attr_reader :agent_run, :command_runner, :config_path, :module_path, :obligation

      def declared_model? = module_path.present? && config_path.present?

      def command_result
        output, status = command_runner.call("tlc -config #{config_path} #{module_path}")
        if output.include?("Model checking completed.")
          attributes("completed", "supported", output)
        elsif output.match?(/invariant.*violation/i)
          attributes("completed", "contradicted", output)
        else
          attributes("execution_error", "unresolved", output, status:)
        end
      end

      def non_applicable(reason)
        record(attributes("non_applicable", "unresolved", "", limitations: reason))
      end

      def attributes(state, coverage, output, status: nil, limitations: nil)
        {
          producer: "formal_verification", execution_state: state, obligation_coverage: coverage,
          input_revision: { "module" => module_path, "config" => config_path },
          evidence_summary: { "output" => output }, recorder_verified: { "exit_status" => status },
          limitations: limitations || "TLC output was parsed; model bounds and assumptions still limit this result."
        }
      end

      def record(attributes)
        LayeredVerificationCheckResult.create!(**attributes, obligation:, agent_run:)
      end
    end
  end
end
