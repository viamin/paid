# frozen_string_literal: true

module LayeredVerification
  module Checks
    class TlcRunner
      # @spec LAYERED-VERIFY-022
      def self.call(...) = new(...).call

      def initialize(module_path:, config_path:, command_runner: nil)
        @module_path, @config_path, @command_runner = module_path, config_path, command_runner
      end

      def call
        return non_applicable("No declared TLA+ module/configuration pair.") unless module_path && config_path
        return non_applicable("The tlc command is unavailable in the isolated execution environment.") unless command_runner

        status, output = command_runner.call("tlc -config #{config_path} #{module_path}")
        return completed(output, "contradicted") if output.include?("Invariant") && output.match?(/violated|failure/i)
        return completed(output, "supported") if output.include?("Model checking completed.")

        { execution_state: "execution_error", obligation_coverage: "unresolved", limitations: "tlc exited #{status} without a recognized result.", evidence: output }
      end

      private

      attr_reader :module_path, :config_path, :command_runner

      def non_applicable(reason) = { execution_state: "non_applicable", obligation_coverage: "unresolved", limitations: reason }
      def completed(output, coverage) = { execution_state: "completed", obligation_coverage: coverage, limitations: "Bounded model-check execution.", evidence: output }
    end
  end
end
