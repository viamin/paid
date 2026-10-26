# frozen_string_literal: true

require "open3"

module LayeredVerification
  module Checks
    # The coordinator invokes this inside the audit's existing isolated
    # workspace. The injected executor keeps command execution out of models.
    # @spec LAYERED-VERIFY-022
    class TlcRunner
      Result = Data.define(:execution_state, :obligation_coverage, :limitations, :evidence)

      def self.call(...) = new(...).call

      def initialize(module_path:, config_path:, executor: Open3)
        @module_path = module_path
        @config_path = config_path
        @executor = executor
      end

      def call
        return unavailable("No declared TLA+ model and configuration pair.") if module_path.blank? || config_path.blank?

        stdout, stderr, status = executor.capture3("tlc", "-config", config_path, module_path)
        classify(stdout:, stderr:, status:)
      rescue Errno::ENOENT
        unavailable("The tlc binary is unavailable in the isolated execution environment.")
      end

      private

      attr_reader :config_path, :executor, :module_path

      def classify(stdout:, stderr:, status:)
        evidence = { "stdout" => stdout, "stderr" => stderr, "exit_status" => status.exitstatus }
        return Result.new("completed", "contradicted", "TLC reported an invariant violation.", evidence) if stdout.match?(/invariant.*violat/i)
        return Result.new("completed", "supported", "TLC completed within its declared model bounds.", evidence) if stdout.include?("Model checking completed.")

        Result.new("execution_error", "unresolved", "TLC exited without a recognized completion or violation result.", evidence)
      end

      def unavailable(reason)
        Result.new("non_applicable", "unresolved", reason, {})
      end
    end
  end
end
