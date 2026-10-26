# frozen_string_literal: true

module LayeredVerification
  module Checks
    # Thin parser around the documented TLC contract; the caller supplies the
    # isolated-execution adapter rather than introducing a broad adapter layer.
    # @spec LAYERED-VERIFY-022
    class TlcRunner
      def self.call(...) = new(...).call

      def initialize(command_runner:, module_path:, config_path:)
        @command_runner = command_runner
        @module_path = module_path
        @config_path = config_path
      end

      def call
        return non_applicable("no declared TLA+ model/config pair") if module_path.blank? || config_path.blank?

        output, status = command_runner.call("tlc", "-config", config_path, module_path)
        return completed(output) if output.include?("Model checking completed.")
        return contradicted(output) if output.match?(/invariant.*violation|error: invariant/i)

        { execution_state: "execution_error", obligation_coverage: "unresolved", limitations: "tlc exited #{status}" }
      rescue Errno::ENOENT
        non_applicable("tlc binary is unavailable")
      end

      private

      attr_reader :command_runner, :config_path, :module_path

      def completed(output)
        { execution_state: "completed", obligation_coverage: "supported", limitations: "TLC checked only the declared bounds and assumptions.", output: }
      end

      def contradicted(output)
        { execution_state: "completed", obligation_coverage: "contradicted", limitations: "Counterexample requires human interpretation.", output: }
      end

      def non_applicable(reason)
        { execution_state: "non_applicable", obligation_coverage: "unresolved", limitations: reason }
      end
    end
  end
end
