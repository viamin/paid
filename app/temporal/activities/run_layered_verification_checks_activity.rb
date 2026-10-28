# frozen_string_literal: true

require "pathname"
require "stringio"

module Activities
  # Executes deterministic plan-selected checks in the already-provisioned
  # isolated environment, before generic agent-result ingestion.
  # @spec LAYERED-VERIFY-008 LAYERED-VERIFY-022 LAYERED-VERIFY-024
  class RunLayeredVerificationChecksActivity < BaseActivity
    activity_name "RunLayeredVerificationChecks"
    COMMAND_TIMEOUT = 60
    EVIDENCE_SUMMARY_MAX_LENGTH = 2_000

    def execute(input)
      @agent_run = AgentRun.find(input[:agent_run_id])
      formal_selections.each { |obligation, plan| run_tlc(obligation, plan) }
      { agent_run_id: agent_run.id, check_result_count: formal_selections.size }
    end

    private

    attr_reader :agent_run

    def formal_selections
      @formal_selections ||= obligations.filter_map do |obligation|
        plan = audit_metadata.fetch("plan", {}).fetch(obligation.id.to_s, {})
        [ obligation, plan ] if Array(plan["selected_checks"]).include?("formal_verification")
      end
    end

    def obligations
      @obligations ||= agent_run.project.layered_verification_obligations
        .where(id: audit_metadata["obligation_ids"]).order(:id).to_a
    end

    def audit_metadata
      @audit_metadata ||= agent_run.external_metadata.fetch("layered_verification")
    end

    def run_tlc(obligation, plan)
      module_path, config_path = model_pair(plan)
      outcome = LayeredVerification::Checks::TlcRunner.call(
        command_runner: method(:run_command), module_path:, config_path:
      )
      LayeredVerificationCheckResult.create!(result_attributes(obligation, outcome))
    end

    def model_pair(plan)
      inputs = Array(plan["required_inputs"]).filter_map { |path| safe_relative_path(path) }
      [ inputs.find { |path| path.end_with?(".tla") }, inputs.find { |path| path.end_with?(".cfg") } ]
    end

    def safe_relative_path(path)
      candidate = Pathname.new(path.to_s)
      clean = candidate.cleanpath.to_s
      clean if !candidate.absolute? && clean != ".." && !clean.start_with?("../")
    end

    def run_command(*command)
      result = agent_run.execute_in_execution_environment(command, timeout: COMMAND_TIMEOUT, stream: false)
      [ [ result[:stdout], result[:stderr] ].compact.join("\n"), result[:exit_code].to_i ]
    end

    def result_attributes(obligation, outcome)
      contradicted = outcome[:obligation_coverage] == "contradicted"
      {
        obligation:, agent_run:, producer: "formal_verification",
        execution_state: outcome.fetch(:execution_state), obligation_coverage: outcome.fetch(:obligation_coverage),
        input_revision: input_revision(obligation), evidence_ref: evidence_ref(obligation, outcome, contradicted:),
        evidence_summary: { "output" => outcome[:output].to_s.truncate(EVIDENCE_SUMMARY_MAX_LENGTH) },
        cause_signature: ("tlc-invariant-violation" if contradicted),
        agent_reported: { "selected_check" => "formal_verification" },
        recorder_verified: { "tlc_output_parsed" => true }, cost: {}, limitations: outcome.fetch(:limitations)
      }
    end

    def evidence_ref(obligation, outcome, contradicted:)
      return unless contradicted

      key = evidence_key(obligation)
      ArtifactStorage.new.upload_io(io: StringIO.new(outcome[:output].to_s), key:, content_type: "text/plain")
      key
    end

    def evidence_key(obligation)
      project = agent_run.project
      "layered-verification/#{project.account_id}/#{project.id}/#{agent_run.id}/#{obligation.id}/tlc-output.txt"
    end

    def input_revision(obligation)
      { "target_revision" => audit_metadata["target_revision"], "external_revision" => obligation.external_revision }.compact
    end
  end
end
