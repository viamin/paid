# frozen_string_literal: true

module LayeredVerification
  module Checks
    class TlcRunner
      # @spec LAYERED-VERIFY-022
      Result = Data.define(:execution_state, :obligation_coverage, :evidence_summary, :limitations, :command)

      def self.call(...) = new(...).call

      def initialize(module_path:, config_path:, command_runner:)
        @module_path = module_path
        @config_path = config_path
        @command_runner = command_runner
      end

      def call
        return unavailable("No declared TLA+ module/config pair.") unless module_path.present? && config_path.present?

        output, success = command_runner.call(command)
        parsed_result(output.to_s, success)
      rescue Errno::ENOENT
        unavailable("The tlc binary is unavailable in the isolated execution environment.")
      end

      private

      attr_reader :module_path, :config_path, :command_runner

      def command = [ "tlc", "-config", config_path, module_path ]

      def parsed_result(output, success)
        return result("completed", "supported", output, "TLC reported successful completion.") if output.include?("Model checking completed.")
        return result("completed", "contradicted", output, "TLC reported an invariant violation.") if output.match?(/Invariant.*violat|Error: Invariant/i)

        result("execution_error", "unresolved", output, success ? "TLC produced no recognized completion marker." : "TLC exited unsuccessfully without a recognized invariant violation.")
      end

      def unavailable(limitations)
        Result.new(execution_state: "non_applicable", obligation_coverage: "unresolved", evidence_summary: {}, limitations:, command: nil)
      end

      def result(execution_state, obligation_coverage, output, limitations)
        Result.new(execution_state:, obligation_coverage:, evidence_summary: { "stdout" => output }, limitations:, command:)
      end
    end
  end
end
