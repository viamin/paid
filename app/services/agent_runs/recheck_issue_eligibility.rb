# frozen_string_literal: true

module AgentRuns
  # RDR-032 hardening: recheck a queued run's issue eligibility at dequeue
  # time. Eager queue seeding creates a queued run the moment an issue
  # becomes eligible, but the issue can lose eligibility before the
  # scheduler claims the run — a skip label added, a new blocking dependency,
  # the issue closed, an untrusted creator, etc. Paid's internal workflow
  # state is intentionally not a dequeue-time exclusion.
  #
  # Those stale queued runs would otherwise hold a unique-active-run slot
  # and pollute the dashboard queue preview forever. Cancel them here so
  # the re-enqueue hooks (sync, paid_state change, dependency close) can
  # recreate the run when the issue becomes eligible again.
  #
  # Only eagerly-seeded auto-pick runs tied to an issue are rechecked:
  # manual runs are an explicit operator request, create_issue / no-issue
  # runs have nothing to recheck, and review goals are PR-scoped with
  # their own retry/limit handling.
  class RecheckIssueEligibility
    # RDR-077: goal -> automation capability, so the dequeue recheck asks the
    # same effective policy the entry points asked when the run was created.
    # @spec AUTOMATION-PHASES-013
    PHASE_CAPABILITIES = {
      "create_pr" => "auto_pick",
      "review" => "auto_scan_prs",
      "enhance_issue" => "auto_enhance",
      "analyze_issue" => "auto_enhance",
      "create_feature" => "create_feature",
      "create_issue" => "auto_pick"
    }.freeze

    FEATURE_ADMISSION_CANCELLATION_REASONS = {
      "issue_dependencies_incomplete" => "This issue has unresolved dependencies. Complete or remove its dependencies to start this run.",
      "in_tree_dependency_incomplete" => "This feature has incomplete prerequisite tasks. Complete the prerequisite tasks to start this run.",
      "feature_revising" => "This feature is being revised. Finish the revision and release the feature to start this run.",
      "feature_not_released" => "This feature is awaiting approval and release. Approve and release the feature to start this run.",
      "no_approved_revision" => "This feature has no approved repository revision. Record an approved revision and release the feature to start this run.",
      "confidence_readiness_incomplete" => "This feature has incomplete readiness requirements. Complete them and release the feature to start this run.",
      "confidence_release_held" => "This feature is awaiting readiness release. Complete its readiness requirements and release the feature to start this run."
    }.freeze

    DEFAULT_FEATURE_ADMISSION_CANCELLATION_REASON = "This feature is not ready to start this run. Review and resolve the feature's admission requirements, then start a new run."

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run, after_claim: false)
      @agent_run = agent_run
      @after_claim = after_claim
    end

    # Returns true when the run was cancelled because its issue is no
    # longer eligible; false when the run should proceed normally.
    def call # @spec EAGER-QUEUE-005 ISSUE-ENHANCEMENT-018
      return cancel_phase_unauthorized_run if phase_revoked?
      return cancel_feature_admission_denied_run if feature_admission_denied?
      return recheck_continuation if continuation_run?
      return recheck_automatic_enhancement_hold if automatic_enhancement_recheck?
      return false unless recheck_applicable?
      return false if issue_still_eligible?

      cancel_run
    end

    private

    attr_reader :agent_run

    def after_claim?
      @after_claim
    end

    # Authorization is rechecked before queued work starts. Disabling a phase
    # or revoking a grant prevents the queued run from starting; it never
    # terminates a run that already started, and manual runs keep the
    # authorization their explicit start carried.
    # @spec AUTOMATION-PHASES-013
    def phase_revoked?
      return false unless agent_run.automatic?
      return false unless Automation::RolloutGuard.enabled?(agent_run.project)

      capability = PHASE_CAPABILITIES[agent_run.goal]
      return false if capability.nil?

      policy = Automation::EffectivePolicy.call(
        project: agent_run.project.reload,
        phase: Automation::Phases.for_capability(capability),
        work_item: agent_run,
        trigger: :automatic
      )
      return false if policy.permitted?

      @phase_policy = policy
      true
    end

    def cancel_phase_unauthorized_run
      cancel_run(reason: "Authorization for #{agent_run.goal} was withdrawn before the run started " \
                         "(#{@phase_policy.reason}); it will be re-seeded when the phase permits it again")
    end

    def continuation_run?
      agent_run.continuation_request_id.present? && agent_run.issue_id.present?
    end

    def recheck_applicable? # @spec EAGER-QUEUE-006 ISSUE-ENHANCEMENT-018
      agent_run.auto_pick? && agent_run.issue_id.present? &&
        !agent_run.review_goal?
    end

    def automatic_enhancement_recheck?
      agent_run.automatic? && agent_run.enhance_issue_goal? && agent_run.issue_id.present?
    end

    def recheck_automatic_enhancement_hold
      return false unless Automation::Strategies::AutoPick::DefaultCandidateSource
        .effective_skip_label_hold?(agent_run.project, agent_run.issue_id)

      cancel_run(reason: "Automatic enhancement is held by an effective automatic-execution control at dequeue.")
    end

    def feature_admission_denied? # @spec FEATURE-APPROVAL-023
      return false unless agent_run.create_pr_goal? && agent_run.issue_id.present?

      @feature_admission = FeatureIntents::RunAdmission.call(issue: agent_run.issue)
      !@feature_admission.allowed?
    end

    def cancel_feature_admission_denied_run
      cancel_run(reason: feature_admission_cancellation_reason)
    end

    def feature_admission_cancellation_reason
      FEATURE_ADMISSION_CANCELLATION_REASONS.fetch(
        @feature_admission.code,
        DEFAULT_FEATURE_ADMISSION_CANCELLATION_REASON
      )
    end

    def issue_still_eligible?
      Automation::Strategies::AutoPick::DefaultCandidateSource
        .eligible_for_dequeue?(
          agent_run.project,
          agent_run.issue_id,
          excluding_run_id: agent_run.id
        )
    end

    # @spec PARTIAL-CLOSEOUT-005 PARTIAL-CLOSEOUT-006
    def recheck_continuation
      issue.reload
      request = agent_run.continuation_request
      return cancel_continuation("Continuation authorization is no longer open.") unless request&.open?
      if issue.closeout_closing?
        return cancel_continuation("Continuation superseded: GitHub closure is in progress.")
      end
      return cancel_continuation("Continuation evidence generation changed.") unless Issues::CloseoutEvidence.call(issue).digest == request.evidence_digest

      # Manual-trigger runs bypass the scheduler's project-pause filters, so
      # explicit operator pauses are honored here instead — a continuation
      # never silently bypasses them (#4120).
      if issue.paused? || agent_run.project.paused? || agent_run.project.quality_paused_at.present?
        return cancel_continuation("Continuation superseded: an explicit operator pause is active.")
      end

      return cancel_continuation("Continuation is no longer eligible at dequeue.") unless continuation_eligible?(request)

      false
    end

    def continuation_eligible?(request)
      Automation::Strategies::AutoPick::DefaultCandidateSource.eligible_for_dequeue?(
        agent_run.project, agent_run.issue_id, excluding_run_id: agent_run.id,
        continuation_authorized_issue_ids: [ request.issue_id ]
      )
    end

    def cancel_continuation(reason)
      request = agent_run.continuation_request
      cancelled = cancel_run(reason:)
      request&.supersede!(reason:) if cancelled
      cancelled
    end

    def issue = agent_run.issue

    # Cancel only queued runs. The scheduler may opt into the narrow
    # post-claim recheck while the run has its private claim sentinel, closing
    # the policy-change race between peek and claim. A workflow ID or running
    # status is already executing and remains owned by the normal lifecycle.
    def cancel_run(reason: nil)
      reason ||= "This issue is no longer eligible for automatic work. " \
                 "It will be queued again when it becomes eligible."

      cancelled = agent_run.with_lock do
        next false unless cancellable_before_execution?

        agent_run.cancel!(error: reason)
      end

      log_cancelled if cancelled
      cancelled
    rescue => e
      log_failure(e)
      false
    end

    def cancellable_before_execution?
      return false unless agent_run.status == "queued"
      return true if agent_run.temporal_workflow_id.nil?

      after_claim? && agent_run.temporal_workflow_id == AgentRun::CLAIMED_SENTINEL
    end

    def log_cancelled
      Rails.logger.info(
        message: "process_run_queue.cancelled_ineligible_issue",
        agent_run_id: agent_run.id,
        project_id: agent_run.project_id,
        issue_id: agent_run.issue_id,
        goal: agent_run.goal
      )
    end

    def log_failure(error)
      Rails.logger.error(
        message: "process_run_queue.recheck_eligibility_failed",
        agent_run_id: agent_run.id,
        issue_id: agent_run.issue_id,
        error: error.message
      )
    end
  end
end
