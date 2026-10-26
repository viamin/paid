# frozen_string_literal: true

module LayeredVerification
  module Checks
    class TlcRunner
      # @spec LAYERED-VERIFY-022
      def self.call(...) = new(...).call

      def initialize(module_path: nil, config_path: nil, command_runner:)
        @module_path = module_path
        @config_path = config_path
        @command_runner = command_runner
      end

      def call
        return non_applicable("No TLA+ model and config pair were declared.") if module_path.blank? || config_path.blank?

        output, success = command_runner.call("tlc -config #{config_path} #{module_path}")
        return completed(output) if output.include?("Model checking completed.")
        return contradicted(output) if output.match?(/invariant.*violation/i)

        failure(output, success)
      rescue Errno::ENOENT
        non_applicable("The tlc binary is not available in the isolated execution environment.")
      end

      private

      attr_reader :module_path, :config_path, :command_runner

      def completed(output) = result("completed", "supported", output, "TLC completed without a reported invariant violation.")
      def contradicted(output) = result("completed", "contradicted", output, "TLC reported an invariant violation; inspect stored counterexample evidence.")
      def failure(output, _success) = result("execution_error", "unresolved", output, "TLC did not emit a recognized completion or violation result.")
      def non_applicable(limitations) = result("non_applicable", "unresolved", nil, limitations)
      def result(state, coverage, output, limitations) = { producer: "formal_verification", execution_state: state, obligation_coverage: coverage, evidence: output, limitations: limitations }
    end
  end
end
