# frozen_string_literal: true

require "open3"

module LayeredVerification
  module Checks
    # Runs the one documented TLA+ command; callers persist the returned shape
    # as an immutable LayeredVerificationCheckResult.
    # @spec LAYERED-VERIFY-022
    class TlcRunner
      Result = Data.define(:execution_state, :obligation_coverage, :evidence_summary, :limitations)

      def self.call(...) = new(...).call

      def initialize(module_path:, config_path:, command_runner: Open3.method(:capture3))
        @module_path = module_path
        @config_path = config_path
        @command_runner = command_runner
      end

      def call
        return non_applicable("No declared TLA+ model/configuration pair.") unless module_path && config_path

        stdout, stderr, status = command_runner.call("tlc", "-config", config_path, module_path)
        output = [ stdout, stderr ].join("\n")
        return completed(output) if output.include?("Model checking completed.")
        return contradicted(output) if output.match?(/invariant.*violat|Error: Invariant/i)

        Result.new(execution_state: "execution_error", obligation_coverage: "unresolved", evidence_summary: { "output" => output }, limitations: "TLC exited #{status.exitstatus} without a recognized result.")
      rescue Errno::ENOENT
        non_applicable("The tlc binary is unavailable in the isolated execution environment.")
      end

      private

      attr_reader :command_runner, :config_path, :module_path

      def completed(output) = Result.new(execution_state: "completed", obligation_coverage: "supported", evidence_summary: { "output" => output }, limitations: "Model checking is bounded by the declared TLC configuration.")
      def contradicted(output) = Result.new(execution_state: "completed", obligation_coverage: "contradicted", evidence_summary: { "counterexample" => output }, limitations: "A TLC counterexample contradicts this scoped claim.")
      def non_applicable(reason) = Result.new(execution_state: "non_applicable", obligation_coverage: "unresolved", evidence_summary: {}, limitations: reason)
    end
  end
end
