# frozen_string_literal: true

module LayeredVerification
  module Checks
    class TlcRunner
      # @spec LAYERED-VERIFY-022
      def self.call(...) = new(...).call

      def initialize(module_path:, config_path:, command_runner:)
        @module_path, @config_path, @command_runner = module_path, config_path, command_runner
      end

      def call
        return non_applicable("no declared TLA+ model") if module_path.blank? || config_path.blank?

        parse(command_runner.call([ "tlc", "-config", config_path, module_path ]))
      rescue Errno::ENOENT
        non_applicable("tlc is not available in the isolated execution environment")
      end

      private

      attr_reader :module_path, :config_path, :command_runner

      def parse(result)
        output = result.fetch(:stdout, "")
        return completed("supported", output) if output.include?("Model checking completed.")
        return completed("contradicted", output) if output.match?(/invariant.*violat/i)

        { execution_state: "execution_error", obligation_coverage: "unresolved", evidence: output,
          limitations: "tlc did not report a completed model check or an invariant violation" }
      end

      def completed(coverage, output)
        { execution_state: "completed", obligation_coverage: coverage, evidence: output,
          limitations: "model checking is bounded by the declared model and configuration" }
      end

      def non_applicable(reason)
        { execution_state: "non_applicable", obligation_coverage: "unresolved", evidence: "", limitations: reason }
      end
    end
  end
end
