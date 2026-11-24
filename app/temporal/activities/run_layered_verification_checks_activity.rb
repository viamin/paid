# frozen_string_literal: true

require "pathname"
require "stringio"

module Activities
  # Executes deterministic plan-selected checks in the already-provisioned
  # isolated environment, before generic agent-result ingestion.
  # @spec LAYERED-VERIFY-008 LAYERED-VERIFY-009 LAYERED-VERIFY-019 LAYERED-VERIFY-022 LAYERED-VERIFY-024
  class RunLayeredVerificationChecksActivity < BaseActivity
    activity_name "RunLayeredVerificationChecks"
    COMMAND_TIMEOUT = 60
    EVIDENCE_SUMMARY_MAX_LENGTH = 2_000

    def execute(input)
      agent_run = AgentRun.find(input[:agent_run_id])
      agent_run.with_lock { execute_locked(agent_run) }
    end

    private

    def execute_locked(agent_run)
      metadata = audit_metadata(agent_run)
      obligations = obligations(agent_run, metadata)
      record_linkage_freshness(agent_run, obligations)
      selections = formal_selections(obligations, metadata)
      selections.each { |obligation, plan| run_selected_check(agent_run, metadata, obligation, plan) }
      { agent_run_id: agent_run.id, check_result_count: selections.size }
    end

    # @spec LAYERED-VERIFY-009
    def record_linkage_freshness(agent_run, obligations)
      obligations.each do |obligation|
        next if recorded?(agent_run, obligation, "linkage_freshness")

        discovery = LayeredVerification::UnmappedMaterial.call(
          obligation:, agent_run:, command_runner: command_runner(agent_run)
        )
        next if discovery.material.empty? && discovery.limitations.empty?

        LayeredVerification::LinkageFreshness.call(
          agent_run:, obligation:, structural_material: discovery.structural_material,
          semantic_material: discovery.semantic_material, limitations: discovery.limitations
        )
      end
    end

    # @spec LAYERED-VERIFY-019
    def run_selected_check(agent_run, metadata, obligation, plan)
      return if recorded?(agent_run, obligation, "formal_verification")
      return if LayeredVerification::Audits::RecordReuse.call(obligation:, agent_run:, metadata:)

      run_tlc(agent_run, metadata, obligation, plan)
    end

    def recorded?(agent_run, obligation, producer)
      LayeredVerificationCheckResult.where(agent_run:, obligation:, producer:).exists?
    end

    def formal_selections(obligations, metadata)
      obligations.filter_map do |obligation|
        plan = metadata.fetch("plan", {}).fetch(obligation.id.to_s, {})
        [ obligation, plan ] if Array(plan["selected_checks"]).include?("formal_verification")
      end
    end

    def obligations(agent_run, metadata)
      agent_run.project.layered_verification_obligations
        .where(id: metadata["obligation_ids"]).order(:id).to_a
    end

    def audit_metadata(agent_run)
      agent_run.external_metadata.fetch("layered_verification")
    end

    def run_tlc(agent_run, metadata, obligation, plan)
      module_path, config_path = model_pair(plan)
      outcome = LayeredVerification::Checks::TlcRunner.call(
        command_runner: command_runner(agent_run), module_path:, config_path:
      )
      LayeredVerificationCheckResult.create!(result_attributes(agent_run, metadata, obligation, outcome))
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

    def command_runner(agent_run) = ->(*command) { run_command(agent_run, *command) }

    def run_command(agent_run, *command)
      result = agent_run.execute_in_execution_environment(command, timeout: COMMAND_TIMEOUT, stream: false)
      [ [ result[:stdout], result[:stderr] ].compact.join("\n"), result[:exit_code].to_i ]
    end

    def result_attributes(agent_run, metadata, obligation, outcome)
      contradicted = outcome[:obligation_coverage] == "contradicted"
      {
        obligation:, agent_run:, producer: "formal_verification",
        execution_state: outcome.fetch(:execution_state), obligation_coverage: outcome.fetch(:obligation_coverage),
        input_revision: input_revision(metadata, obligation), evidence_ref: evidence_ref(agent_run, obligation, outcome, contradicted:),
        evidence_summary: { "output" => outcome[:output].to_s.truncate(EVIDENCE_SUMMARY_MAX_LENGTH) },
        cause_signature: ("tlc-invariant-violation" if contradicted),
        agent_reported: { "selected_check" => "formal_verification" },
        recorder_verified: { "tlc_output_parsed" => true }, cost: {}, limitations: outcome.fetch(:limitations)
      }
    end

    def evidence_ref(agent_run, obligation, outcome, contradicted:)
      return unless contradicted

      key = evidence_key(agent_run, obligation)
      ArtifactStorage.new.upload_io(io: StringIO.new(outcome[:output].to_s), key:, content_type: "text/plain")
      key
    end

    def evidence_key(agent_run, obligation)
      project = agent_run.project
      "layered-verification/#{project.account_id}/#{project.id}/#{agent_run.id}/#{obligation.id}/tlc-output.txt"
    end

    def input_revision(metadata, obligation)
      scope = LayeredVerification::ScopeSnapshot.call(obligation)
      { "target_revision" => metadata["target_revision"], "code" => metadata["target_revision"],
        "external_revision" => obligation.external_revision,
        "scope_paths" => (scope.paths if scope.complete),
        "dependencies" => metadata.fetch("dependencies", {}) }.compact
    end
  end
end
