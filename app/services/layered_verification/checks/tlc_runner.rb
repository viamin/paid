# frozen_string_literal: true

module LayeredVerification
  module Checks
    class TlcRunner
      # @spec LAYERED-VERIFY-022
      Result = Data.define(:execution_state, :obligation_coverage, :evidence_ref, :limitations)

      def self.call(...)
        new(...).call
      end

      def initialize(model_path:, config_path:, command_runner:)
        @model_path = model_path
        @config_path = config_path
        @command_runner = command_runner
      end

      def call
        return non_applicable("No declared TLA+ model is available.") unless model_path.present?
        return non_applicable("The TLA+ model config pair is missing.") unless config_path.present?

        result = command_runner.call(command: [ "tlc", "-config", config_path, model_path ])
        parse(result)
      rescue Errno::ENOENT
        non_applicable("The tlc binary is unavailable in the isolated execution environment.")
      end

      private

      attr_reader :command_runner, :config_path, :model_path

      def parse(result)
        output = [ result.fetch(:stdout, ""), result.fetch(:stderr, "") ].join("\n")
        return Result.new("completed", "supported", result[:evidence_ref], "TLC completed within its declared model bounds.") if output.include?("Model checking completed.")
        return Result.new("completed", "contradicted", result[:evidence_ref], "TLC reported an invariant violation.") if output.match?(/invariant.*violat/i)

        Result.new("execution_error", "unresolved", result[:evidence_ref], "TLC exited without a recognized completion result.")
      end

      def non_applicable(reason)
        Result.new("non_applicable", "unresolved", nil, reason)
      end
    end
  end
end
