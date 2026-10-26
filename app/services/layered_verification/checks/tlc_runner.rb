# frozen_string_literal: true

module LayeredVerification
  module Checks
    class TlcRunner
      # @spec LAYERED-VERIFY-022
      def self.call(...) = new(...).call
      def initialize(obligation:, agent_run:, model:, execute: nil)
        @obligation, @agent_run, @model, @execute = obligation, agent_run, model, execute || method(:run_command)
      end
      def call
        return record("non_applicable", "unresolved", "no declared formal model") if model.blank?
        return record("non_applicable", "unresolved", "declared model is missing its module or config") unless model.values_at(:module, :config).all?(&:present?)
        output, success = execute.call([ "tlc", "-config", model.fetch(:config), model.fetch(:module) ])
        return record("completed", "supported", "TLC completed without reporting a counterexample", output) if success && output.include?("Model checking completed.")
        return record("completed", "contradicted", "TLC reported an invariant violation", output) if output.match?(/invariant.*violat/i)

        record("execution_error", "unresolved", "TLC did not produce a recognized completion result", output)
      rescue Errno::ENOENT
        record("non_applicable", "unresolved", "tlc binary is unavailable")
      end
      private
      attr_reader :obligation, :agent_run, :model, :execute
      def record(state, coverage, limitations, output = nil)
        LayeredVerificationCheckResult.create!(obligation:, agent_run:, producer: "formal_verification", execution_state: state, obligation_coverage: coverage, input_revision: { "module" => model&.fetch(:module, nil), "config" => model&.fetch(:config, nil) }, evidence_summary: { "output" => output.to_s }, limitations:)
      end

      def run_command(command)
        require "open3"
        output, status = Open3.capture2e(*command)
        [ output, status.success? ]
      end
    end
  end
end
