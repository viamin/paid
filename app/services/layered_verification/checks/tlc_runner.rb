# frozen_string_literal: true

require "open3"

module LayeredVerification
  module Checks
    class TlcRunner
      # @spec LAYERED-VERIFY-022
      def self.call(...) = new(...).call

      def initialize(obligation:, agent_run:, module_path: nil, config_path: nil, command_runner: Open3)
        @obligation, @agent_run, @module_path, @config_path, @command_runner = obligation, agent_run, module_path, config_path, command_runner
      end

      def call
        return record_non_applicable("No declared TLA+ module/configuration pair is available.") unless paths_present?

        output, status = command_runner.capture2e("tlc", "-config", config_path, module_path)
        record(output:, status: status.success?)
      rescue Errno::ENOENT
        record_non_applicable("The documented tlc command is not available in the isolated environment.")
      end

      private

      attr_reader :agent_run, :command_runner, :config_path, :module_path, :obligation

      def paths_present? = module_path.present? && config_path.present?

      def record(output:, status:)
        coverage = output.include?("Invariant") && output.match?(/violat|fail/i) ? "contradicted" : "supported"
        execution_state = output.include?("Model checking completed.") || coverage == "contradicted" ? "completed" : "execution_error"
        LayeredVerificationCheckResult.create!(obligation:, agent_run:, producer: "formal_verification", execution_state:,
          obligation_coverage: coverage == "supported" && !status ? "unresolved" : coverage, input_revision: { "code" => agent_run.base_commit_sha },
          evidence_summary: { "output" => output }, agent_reported: {}, recorder_verified: { "exit_success" => status }, cost: {},
          limitations: execution_state == "execution_error" ? "tlc did not emit a supported completion or invariant-violation result." : "TLC assesses only the declared model and configuration.")
      end

      def record_non_applicable(limitations)
        LayeredVerificationCheckResult.create!(obligation:, agent_run:, producer: "formal_verification", execution_state: "non_applicable",
          obligation_coverage: "unresolved", input_revision: { "code" => agent_run.base_commit_sha }, evidence_summary: {},
          agent_reported: {}, recorder_verified: {}, cost: {}, limitations:)
      end
    end
  end
end
