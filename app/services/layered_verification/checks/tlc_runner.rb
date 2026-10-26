# frozen_string_literal: true

module LayeredVerification
  module Checks
    class TlcRunner
      # @spec LAYERED-VERIFY-022
      def self.call(...) = new(...).call

      def initialize(executor:, module_path: nil, config_path: nil)
        @executor = executor
        @module_path = module_path
        @config_path = config_path
      end

      def call
        return result("non_applicable", "unresolved", "No declared TLA+ module/config pair.") if module_path.blank? || config_path.blank?

        output, success = executor.call("tlc -config #{config_path} #{module_path}")
        return result("completed", "contradicted", "TLC reported an invariant violation.", output) if output.include?("Invariant") && output.match?(/violation|violated/i)
        return result("completed", "supported", "TLC completed within its declared model bounds.", output) if output.include?("Model checking completed.")

        result(success ? "incomplete" : "execution_error", "unresolved", "TLC did not produce a recognized completion result.", output)
      rescue Errno::ENOENT
        result("non_applicable", "unresolved", "The tlc binary is unavailable in the isolated environment.")
      end

      private

      attr_reader :executor, :module_path, :config_path

      def result(execution_state, obligation_coverage, limitations, evidence = nil)
        { producer: "formal_verification", execution_state:, obligation_coverage:, limitations:, evidence_ref: evidence }
      end
    end
  end
end
