# frozen_string_literal: true

module LayeredVerification
  module Checks
    # Runs the documented TLA+ model-check command and records its outcome as
    # a `formal_verification` check result.
    #
    # A missing binary, a missing config pair, and a project without a
    # declared model are explicit `non_applicable` gaps with a stated reason,
    # never a silent skip and never a pass. A completed model check
    # establishes only what the model checked: it does not establish
    # business-to-model or model-to-code correspondence, so its coverage
    # against the obligation stays `unresolved` unless the checker reported a
    # violation.
    #
    # @spec LAYERED-VERIFY-022
    class TlcRunner
      PRODUCER = "formal_verification"
      COMPLETED_PATTERN = /Model checking completed\./
      VIOLATION_PATTERN = /Invariant\s+(\S+)\s+is violated/
      MISSING_BINARY_PATTERN = /(tlc: command not found|command not found|tlc: not found)/i
      MAX_EXCERPT = 4_000

      def self.call(...)
        new(...).call
      end

      def initialize(project:, obligation:, model:, executor:, agent_run: nil, evidence_store: nil)
        @project = project
        @obligation = obligation
        @model = model
        @executor = executor
        @agent_run = agent_run
        @evidence_store = evidence_store
      end

      def call
        return non_applicable("No formal model is declared for this project, so no model check ran.") if model.blank?
        return non_applicable("The declared model has no matching config file, so no model check ran.") unless config_present?

        execution = executor.call(command, working_dir: working_dir)
        return incomplete(execution.unavailable_reason) unless execution.available?
        return non_applicable("The tlc binary is not available in the execution environment.") if missing_binary?(execution)

        interpret(execution)
      end

      private

      attr_reader :agent_run, :evidence_store, :executor, :model, :obligation, :project

      def interpret(execution)
        output = "#{execution.stdout}\n#{execution.stderr}"

        if output.match?(VIOLATION_PATTERN)
          contradicted(execution, output)
        elsif execution.stdout.match?(COMPLETED_PATTERN)
          completed(execution)
        elsif execution.exit_code.to_i.positive?
          execution_error(execution, output)
        else
          incomplete("The model checker finished without reporting a recognized outcome.", execution)
        end
      end

      def contradicted(execution, output)
        counterexample = counterexample_excerpt(output)
        stored = store_evidence(counterexample)

        record(
          execution_state: "completed",
          obligation_coverage: "contradicted",
          limitations: "The model checker reported an invariant violation; the model and the code still have to be compared before the cause is known.",
          evidence_ref: stored&.key,
          evidence_summary: {
            "exit_code" => execution.exit_code,
            "counterexample" => counterexample,
            "evidence_url" => stored&.url
          }.compact
        )
      end

      def completed(execution)
        record(
          execution_state: "completed",
          obligation_coverage: "unresolved",
          limitations: "The model's own checked properties held; this establishes nothing about how the model corresponds to the business intent or the implementation.",
          evidence_summary: { "exit_code" => execution.exit_code }
        )
      end

      def execution_error(execution, output)
        record(
          execution_state: "execution_error",
          obligation_coverage: "unresolved",
          limitations: "The model checker exited with status #{execution.exit_code} without reporting a recognized outcome.",
          evidence_summary: { "exit_code" => execution.exit_code, "output_excerpt" => excerpt(output) }
        )
      end

      def incomplete(reason, execution = nil)
        record(
          execution_state: "incomplete",
          obligation_coverage: "unresolved",
          limitations: reason,
          evidence_summary: execution ? { "exit_code" => execution.exit_code } : {}
        )
      end

      def non_applicable(reason)
        record(
          execution_state: "non_applicable",
          obligation_coverage: "unresolved",
          limitations: reason,
          evidence_summary: {}
        )
      end

      def record(execution_state:, obligation_coverage:, limitations:, evidence_ref: nil, evidence_summary: {})
        LayeredVerificationCheckResult.create!(
          obligation: obligation,
          agent_run: agent_run,
          producer: PRODUCER,
          execution_state: execution_state,
          obligation_coverage: obligation_coverage,
          input_revision: input_revision,
          evidence_ref: evidence_ref,
          evidence_summary: evidence_summary,
          agent_reported: {},
          recorder_verified: { "command" => command, "working_dir" => working_dir },
          cost: { "tokens" => 0 },
          limitations: limitations
        )
      end

      def input_revision
        {
          "external_revision" => obligation.external_revision,
          "target_revision" => agent_run&.base_commit_sha,
          "model" => model
        }.compact
      end

      def command
        "tlc -config #{model.fetch('config')} #{model.fetch('module')}.tla"
      end

      def working_dir
        model["directory"].presence
      end

      def config_present?
        model["config_present"] != false
      end

      def missing_binary?(execution)
        "#{execution.stdout}\n#{execution.stderr}".match?(MISSING_BINARY_PATTERN)
      end

      def counterexample_excerpt(output)
        lines = output.lines
        start = lines.index { |line| line.match?(VIOLATION_PATTERN) } || 0
        lines[start, 40].join.truncate(MAX_EXCERPT)
      end

      def excerpt(output)
        output.to_s.truncate(MAX_EXCERPT)
      end

      def store_evidence(content)
        store = evidence_store || LayeredVerification::Evidence::Store.new(
          key: "layered-verification/#{project.id}/#{obligation.id}/tlc-#{Time.current.to_i}.txt"
        )
        store.call(content)
      end
    end
  end
end
