# frozen_string_literal: true

module CloseoutVerifications
  # Claims an admitted verification. Merge targets use the isolated technical
  # executor; live targets use only the existing allowlisted read-only check.
  # @spec STAGED-CLOSEOUT-ADOPTION-011 STAGED-CLOSEOUT-ADOPTION-012 PARTIAL-CLOSEOUT-057
  class Execute
    EVIDENCE_KEY = "closeout_verification".freeze
    TERMINAL_STATUSES = %w[completed failed cancelled].freeze
    Claim = Data.define(:requirement, :reason, :terminal) do
      def ready? = requirement.present?
      def terminal? = terminal
    end

    def self.call(...) = new(...).call

    def self.record_exception!(agent_run:, error:)
      new(agent_run:).record_exception!(error)
    end

    def initialize(agent_run:, validation_executor: TechnicalPrerequisites::ValidateExecution)
      @agent_run = agent_run
      @validation_executor = validation_executor
    end

    def call
      return if record_cancelled!
      return if terminal?

      return execute_live_target if live_target?

      claim = claim!
      return unless claim

      result = validation_executor.call(agent_run:, native_command: claim.command)
      schedule_audit_if_new_evidence(finish!(result, command: claim.command))
    end

    def record_exception!(error)
      schedule_audit_if_new_evidence(finish_exception!(error))
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

        claim = admitted_requirement
        unless claim.ready?
          record_terminal!("stale", error: claim.reason) if claim.terminal?
          return
        end

        agent_run.update!(status: "running", started_at: Time.current)
        claim.requirement
      end
    end

    def admitted_requirement
      return stale("run is not an admitted closeout verification") unless agent_run.goal == AgentRun::CLOSEOUT_VERIFICATION_GOAL && agent_run.synthetic?

      mapping = StagedCloseoutMapping.find_by(id: agent_run.closeout_mapping_id)
      return stale("reviewed mapping is unavailable") unless mapping && pinned_mapping?(mapping)
      return stale("merged target changed or is unavailable") unless merged_target?(mapping)
      return deferred("project authority is paused") if paused?
      return stale("automatic release policy is no longer permitted") unless policy_permitted?(mapping)
      return deferred("budget is unavailable: #{budget[:reason]}") unless budget[:allowed]
      return claim_for_eligibility unless eligibility.eligible?

      requirement = PreCommitRequirement.resolve(project: agent_run.project, user: nil)
        .find { |candidate| candidate.id.to_s == mapping.target_key }
      return stale("reviewed recipe is unavailable") unless requirement&.command.present?

      Claim.new(requirement, nil, false)
    end

    def execute_live_target
      attempt = claim_live_target!
      return unless attempt

      attempt = TrustedMeasurements::RunCheck.call(
        project: agent_run.project, check_key: @live_mapping.target_key,
        external_issue_number: agent_run.issue.github_number, criterion_key: agent_run.closeout_criterion_key,
        expected_deployed_revision: agent_run.closeout_target_revision
      )
      finish_live_target!(attempt)
    rescue StandardError
      attempt = current_live_attempt
      raise unless attempt

      finish_live_target!(attempt)
      raise
    end

    def claim_for_eligibility
      reason = "reviewed mapping is stale: #{eligibility.reason}"
      eligibility.reason == "closeout assessment is stale" ? deferred(reason) : stale(reason)
    end

    def stale(reason) = Claim.new(nil, reason, true)
    def deferred(reason) = Claim.new(nil, reason, false)

    def pinned_mapping?(mapping)
      mapping.issue_id == agent_run.issue_id && mapping.stage == "merged_revision" &&
        mapping.execution_path == "technical_prerequisite" &&
        mapping.criterion_key == agent_run.closeout_criterion_key &&
        mapping.target_version == agent_run.closeout_recipe_version &&
        mapping.target_digest == agent_run.closeout_recipe_digest
    end

    def live_target? = agent_run.closeout_target_revision.present?

    def claim_live_target!
      agent_run.with_lock do
        return unless agent_run.status == "queued"
        unless agent_run.goal == AgentRun::CLOSEOUT_VERIFICATION_GOAL && agent_run.synthetic?
          record_terminal!("stale", error: "run is not an admitted closeout verification")
          return
        end
        return if paused? || !Project.active.where(id: agent_run.project_id).exists?
        return unless budget[:allowed]

        mapping = StagedCloseoutMapping.find_by(id: agent_run.closeout_mapping_id)
        unless mapping && mapping.stage == "live_environment" && mapping.execution_path == "trusted_measurement" &&
            mapping.issue_id == agent_run.issue_id && mapping.criterion_key == agent_run.closeout_criterion_key &&
            mapping.target_version == agent_run.closeout_recipe_version && mapping.target_digest == agent_run.closeout_recipe_digest &&
            mapping.environment_class == agent_run.closeout_environment && mapping.environment_class == Rails.env.to_s &&
            StagedCloseoutAdoption::Mappings.eligible_for(mapping:, project: agent_run.project, issue: agent_run.issue,
              observed_target: "live_environment").eligible?
          record_terminal!("stale", error: "reviewed live mapping is stale or unavailable")
          return
        end
        if TrustedMeasurements::DeploymentSignal.current != agent_run.closeout_target_revision
          record_terminal!("stale", error: "confirmed environment target changed or is unavailable")
          return
        end

        agent_run.update!(status: "running", started_at: Time.current)
        @live_mapping = mapping
      end
      true
    end

    def finish_live_target!(attempt)
      outcome = nil
      agent_run.with_lock do
        return if terminal?

        changed_target = TrustedMeasurements::DeploymentSignal.current != agent_run.closeout_target_revision
        outcome = changed_target ? "stale" : attempt&.succeeded? ? "observed" : attempt&.failed? ? "failed" : "unknown"
        evidence = identity_evidence.merge(
          "outcome" => outcome, "recorded_at" => Time.current.iso8601,
          "target_revision" => agent_run.closeout_target_revision,
          "measurement_attempt_id" => attempt&.id, "measurement_status" => attempt&.status,
          "measurement_result" => attempt&.result, "measurement_failure_reason" => attempt&.failure_reason,
          "measurement_executed_at" => attempt&.executed_at&.utc&.iso8601(6),
          "environment" => { "mapping_environment_class" => agent_run.closeout_environment,
                             "target_revision" => agent_run.closeout_target_revision }
        ).compact
        agent_run.update!(closeout_measurement_attempt: attempt,
          status: outcome == "observed" ? "completed" : "failed", completed_at: Time.current,
          error_message: changed_target ? "confirmed environment target changed during collection" : attempt&.failure_reason,
          verification_result: agent_run.verification_result.merge(EVIDENCE_KEY => evidence))
      end
      schedule_audit_if_new_evidence(outcome)
    end

    def current_live_attempt
      return unless @live_mapping

      TrustedMeasurementAttempt.find_by(project: agent_run.project, issue: agent_run.issue,
        check_key: @live_mapping.target_key, check_version: @live_mapping.target_version,
        criterion_key: agent_run.closeout_criterion_key,
        external_issue_number: agent_run.issue.github_number,
        deployed_revision: agent_run.closeout_target_revision)
    end

    def merged_target?(mapping)
      source_pr = agent_run.project.issues.find_by(github_number: agent_run.source_pull_request_number, is_pull_request: true)
      source_pr&.merged_commit_sha == agent_run.base_commit_sha && mapping.issue_id == agent_run.issue_id
    end

    # @spec STAGED-CLOSEOUT-ADOPTION-016
    def paused?
      project = agent_run.project
      project.paused? || project.scheduler_paused? || project.quality_paused? || project.account.scheduler_paused? ||
        Issue.where(id: agent_run.issue_id, project_id: project.id, paused: true).exists?
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
        return if persist_cancelled!(command:, technical_evidence: result.evidence)
        return if terminal?

        outcome = outcome_for(result)
        record_terminal!(outcome, command:, technical_evidence: persisted_technical_evidence.presence || result.evidence)
        outcome
      end
    end

    def finish_exception!(error)
      agent_run.with_lock do
        return if persist_cancelled!(error: error.message)
        return if terminal?

        outcome = error.is_a?(ApplicationJob::PerformTimeoutError) ? "timeout" : "setup_failed"
        record_terminal!(outcome, error: error.message)
        outcome
      end
    end

    # Scheduled outside the run lock, mirroring
    # TechnicalPrerequisiteValidationJob#finish!: a scheduling failure here
    # must not roll back the terminal status already persisted on this run.
    # A cancelled outcome is a withdrawal, not new evidence, and does not
    # schedule an audit.
    def schedule_audit_if_new_evidence(outcome)
      return unless outcome && outcome != "cancelled"
      return unless Evidence.current_for_run?(agent_run)

      PartialCloseouts::AutoAudit.call(issue: agent_run.issue)
    end

    def record_cancelled!
      agent_run.with_lock do
        persist_cancelled!
      end
    end

    def persist_cancelled!(**evidence)
      return false unless agent_run.status == "cancelled"

      evidence[:technical_evidence] = persisted_technical_evidence.presence || evidence[:technical_evidence]
      record_terminal!("cancelled", **evidence) unless agent_run.verification_result.key?(EVIDENCE_KEY)
      true
    end

    def outcome_for(result)
      return "cancelled" if result.status == "cancelled"
      return "unavailable" if result.status == "unavailable"
      return "cleanup_failed" if cleanup_failed?(result)
      return "setup_failed" if setup_failed?(result)
      result.success? ? "passed" : "failed"
    end

    # ValidateExecution rescues isolated-environment setup failures into a
    # failed Result. A recipe command failure instead supplies native command
    # evidence, so preserve the setup failure as a distinct closeout outcome.
    def setup_failed?(result)
      result.status == "failed" && result.evidence["error"].present? && result.evidence["native"].blank?
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

    def persisted_technical_evidence
      agent_run.verification_result[TechnicalPrerequisites::EVIDENCE_KEY]
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
        "generation" => agent_run.closeout_verification_generation,
        "environment" => (persisted_technical_evidence&.fetch("environment", {}) || {}).merge(
          "mapping_environment_class" => mapping&.environment_class
        )
      }
    end

    def terminal?
      TERMINAL_STATUSES.include?(agent_run.reload.status)
    end
  end
end
