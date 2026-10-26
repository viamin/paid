# frozen_string_literal: true

module LayeredVerification
  module Checks
    # Converts the documented TLC command's observable result into the durable
    # check-result vocabulary. Execution remains in the existing container.
    # @spec LAYERED-VERIFY-022
    class TlcRunner
      Result = Data.define(:producer, :execution_state, :obligation_coverage, :limitations, :evidence_summary, :command)

      def self.call(...)
        new(...).call
      end

      def initialize(command_runner:, module_path:, config_path:)
        @command_runner = command_runner
        @module_path = module_path
        @config_path = config_path
      end

      def call
        return non_applicable("No declared TLA+ model and configuration pair is available.") unless paths_present?

        classify(command_runner.call(command))
      rescue Errno::ENOENT
        non_applicable("The tlc binary is unavailable in the isolated execution environment.")
      end

      private

      attr_reader :command_runner, :config_path, :module_path

      def command
        [ "tlc", "-config", config_path, module_path ]
      end

      def paths_present?
        module_path.present? && config_path.present?
      end

      def classify(raw)
        output = (raw[:output] || raw["output"]).to_s
        if output.include?("Invariant") && output.match?(/violated|violation/i)
          Result.new("formal_verification", "completed", "contradicted", "TLC reported an invariant violation.", { "output" => output }, command)
        elsif output.include?("Model checking completed.")
          Result.new("formal_verification", "completed", "supported", "TLC only establishes the declared properties and bounds.", { "output" => output }, command)
        else
          Result.new("formal_verification", "execution_error", "unresolved", "TLC did not produce a recognized completion or invariant violation.", { "output" => output }, command)
        end
      end

      def non_applicable(limitations)
        Result.new("formal_verification", "non_applicable", "unresolved", limitations, {}, nil)
      end
    end
  end
end
