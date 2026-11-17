# frozen_string_literal: true

module CloseoutVerifications
  # Claims an admitted merge-bound verification and delegates repository work to
  # the existing isolated technical-prerequisite executor.
  # @spec STAGED-CLOSEOUT-ADOPTION-011
  class Execute
    EVIDENCE_KEY = "closeout_verification".freeze
    TERMINAL_STATUSES = %w[completed failed cancelled].freeze

    def self.call(...) = new(...).call

    def self.record_exception!(agent_run:, error:)
      new(agent_run:).record_exception!(error)
    end

    def initialize(agent_run:, validation_executor: TechnicalPrerequisites::ValidateExecution)
      @agent_run = agent_run
      @validation_executor = validation_executor
    end

    def call
      return if terminal?

      requirement = claim!
      return unless requirement

      result = validation_executor.call(agent_run:, native_command: requirement.command)
      finish!(result, command: requirement.command)
    end

    def record_exception!(error)
      return if terminal?

      finish_exception!(error)
    end

    private

    attr_reader :agent_run, :validation_executor

    def claim!
      agent_run.with_lock do
        # Claim exactly once: with_lock reloads the row under a database lock,
        # so only a delivery that observes `queued` may start execution. A
        # duplicate delivery against a running attempt must not relaunch the
        # reviewed command or race the evidence write.
        return unless agent_run.status == "queued"

        requirement, reason = admitted_requirement
        unless requirement
          record_terminal!("stale", error: reason)
          return
        end

        agent_run.update!(status: "running", started_at: Time.current)
        requirement
      end
    end

    def admitted_requirement
      return [ nil, "run is not an admitted closeout verification" ] unless agent_run.goal == AgentRun::CLOSEOUT_VERIFICATION_GOAL && agent_run.synthetic?

      mapping = StagedCloseoutMapping.find_by(id: agent_run.closeout_mapping_id)
      return [ nil, "reviewed mapping is unavailable" ] unless mapping && pinned_mapping?(mapping)
      return [ nil, "merged target changed or is unavailable" ] unless merged_target?(mapping)
      return [ nil, "project authority is paused" ] if paused?
      return [ nil, "automatic release policy is no longer permitted" ] unless policy_permitted?(mapping)
      return [ nil, "budget is unavailable: #{budget[:reason]}" ] unless budget[:allowed]
      return [ nil, "reviewed mapping is stale: #{eligibility.reason}" ] unless eligibility.eligible?

      requirement = PreCommitRequirement.resolve(project: agent_run.project, user: nil)
        .find { |candidate| candidate.id.to_s == mapping.target_key }
      return [ nil, "reviewed recipe is unavailable" ] unless requirement&.command.present?

      [ requirement, nil ]
    end

    def pinned_mapping?(mapping)
      mapping.issue_id == agent_run.issue_id && mapping.stage == "merged_revision" &&
        mapping.execution_path == "technical_prerequisite" &&
        mapping.criterion_key == agent_run.closeout_criterion_key &&
        mapping.target_version == agent_run.closeout_recipe_version &&
        mapping.target_digest == agent_run.closeout_recipe_digest
    end

    def merged_target?(mapping)
      source_pr = agent_run.project.issues.find_by(github_number: agent_run.source_pull_request_number, is_pull_request: true)
      source_pr&.merged_commit_sha == agent_run.base_commit_sha && mapping.issue_id == agent_run.issue_id
    end

    def paused?
      project = agent_run.project
      project.paused? || project.scheduler_paused? || project.quality_paused? || project.account.scheduler_paused?
    end

    def policy_permitted?(mapping)
      Automation::EffectivePolicy.call(project: agent_run.project, phase: mapping.phase,
        work_item: agent_run.issue, trigger: :automatic).permitted?
    end

    def budget = @budget ||= CostBudgets::Check.call(agent_run.project, agent_run:)

    def eligibility
      @eligibility ||= StagedCloseoutAdoption::Mappings.eligible_for(mapping: StagedCloseoutMapping.find(agent_run.closeout_mapping_id),
        project: agent_run.project, issue: agent_run.issue, observed_merge: true)
    end

    def finish!(result, command:)
      agent_run.with_lock do
        return if terminal?

        outcome = outcome_for(result)
        record_terminal!(outcome, command:, technical_evidence: result.evidence)
      end
    end

    def finish_exception!(error)
      agent_run.with_lock do
        return if terminal?

        outcome = error.is_a?(ApplicationJob::PerformTimeoutError) ? "timeout" : "setup_failed"
        record_terminal!(outcome, error: error.message)
      end
    end

    def outcome_for(result)
      return "cancelled" if result.status == "cancelled"
      return "unavailable" if result.status == "unavailable"
      return "cleanup_failed" if cleanup_failed?(result)
      result.success? ? "passed" : "failed"
    end

    # ValidateExecution writes the authoritative cleanup verdict into the run's
    # persisted technical record after building the returned Result, whose
    # cleanup entry then only records that cleanup was attempted. finish! holds
    # the run lock and has reloaded it, so the persisted record decides.
    def cleanup_failed?(result)
      result.evidence.dig("cleanup", "completed") == false ||
        agent_run.verification_result.dig(TechnicalPrerequisites::EVIDENCE_KEY, "cleanup", "completed") == false
    end

    def record_terminal!(outcome, command: nil, technical_evidence: nil, error: nil)
      now = Time.current
      evidence = identity_evidence.merge(
        "outcome" => outcome,
        "recorded_at" => now.iso8601,
        "command" => command,
        "technical_evidence" => technical_evidence,
        "error" => error
      ).compact
      agent_run.update!(
        status: outcome == "cancelled" ? "cancelled" : (outcome == "passed" ? "completed" : "failed"),
        completed_at: now,
        error_message: error || technical_evidence&.dig("error") || (outcome == "passed" ? nil : outcome),
        verification_result: agent_run.verification_result.merge(EVIDENCE_KEY => evidence)
      )
    end

    def identity_evidence
      mapping = StagedCloseoutMapping.find_by(id: agent_run.closeout_mapping_id)
      {
        "source_issue_id" => agent_run.issue_id,
        "criterion" => agent_run.closeout_criterion_key,
        "source_pr_number" => agent_run.source_pull_request_number,
        "merged_commit_sha" => agent_run.base_commit_sha,
        "recipe_version" => agent_run.closeout_recipe_version,
        "recipe_digest" => agent_run.closeout_recipe_digest,
        "mapping_id" => agent_run.closeout_mapping_id,
        "environment" => { "container_host" => agent_run.container_host, "mapping_environment_class" => mapping&.environment_class }
      }
    end

    def terminal?
      TERMINAL_STATUSES.include?(agent_run.reload.status)
    end
  end
end
