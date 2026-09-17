# frozen_string_literal: true

module IntentConformance
  # RDR-067 final-merge precondition (#3868): re-verifies the PR head, the
  # feature's approved design revision, and verdict identity immediately
  # before requesting merge — independent of any cached scan-time signal — so
  # a push or design amendment between scan and merge cannot bypass the gate.
  # No fallback interprets a missing or stale verdict as approval.
  #
  # A no-op (returns +nil+) for any issue not linked to a FeatureIntent, or
  # when the project has not opted into the +approved_intent_amendments+
  # rollout flag: existing projects and non-feature PRs are unaffected.
  # @spec INTENT-MERGE-GUARD-001
  # @spec INTENT-MERGE-GUARD-002
  # @spec INTENT-MERGE-GUARD-003
  # @spec INTENT-MERGE-GUARD-004
  # @spec INTENT-MERGE-GUARD-005
  # @spec INTENT-MERGE-GUARD-006
  # @spec INTENT-MERGE-GUARD-007
  # @spec INTENT-MERGE-GUARD-008
  class VerifyAtMerge
    Blocker = ::Data.define(:reason_code, :message)

    REASON_REVISING = "design_revision_in_progress"
    REASON_PAUSED = "design_amendment_hold"
    REASON_VERDICT_MISSING = "verdict_missing"
    REASON_VERDICT_STALE = "verdict_stale"
    REASON_MATERIAL_DRIFT = "material_drift"
    REASON_UNCERTAIN = "uncertain"
    REASON_NOT_EVALUATED = "not_evaluated"

    def self.call(...)
      new(...).call
    end

    def initialize(project:, issue:, pr_head_sha:)
      @project = project
      @issue = issue
      @pr_head_sha = pr_head_sha
    end

    # Returns +nil+ when the pull request may proceed to the project's other
    # merge preconditions, or a +Blocker+ describing why it may not.
    def call
      return nil unless applicable?
      return blocker(REASON_REVISING, "The feature's approved design is under amendment (revising).") if feature_intent.revising?
      return blocker(REASON_PAUSED, "This branch is paused pending a design-amendment impact decision.") if paused?

      verdict = IntentConformanceVerdict.latest_for(issue)
      return blocker(REASON_VERDICT_MISSING, "No intent-conformance verdict exists for this pull request.") if verdict.blank?
      return blocker(REASON_VERDICT_STALE, stale_message) unless current_verdict?(verdict)
      return nil if verdict.within_scope?
      return nil if exception_authorizes_merge?

      drift_blocker(verdict)
    end

    private

    attr_reader :project, :issue, :pr_head_sha

    def applicable?
      feature_intent.present? && FeatureFlags.enabled?(:approved_intent_amendments, project: project)
    end

    def feature_intent
      @feature_intent ||= issue.feature_intent
    end

    def paused?
      DesignAmendmentPause.held.where(issue_id: issue.id).exists?
    end

    def current_verdict?(verdict)
      verdict.current_for?(pr_head_sha: pr_head_sha, approved_design_revision: feature_intent.approved_design_revision)
    end

    def stale_message
      "The recorded verdict does not match the current PR head or the feature's approved design revision."
    end

    def exception_authorizes_merge?
      IntentConformanceResolution.exists?(
        issue_id: issue.id,
        pr_head_sha: pr_head_sha,
        resolution_type: "implementation_exception"
      )
    end

    def drift_blocker(verdict)
      case verdict.outcome
      when IntentConformanceVerdict::OUTCOME_MATERIAL_DRIFT
        blocker(REASON_MATERIAL_DRIFT, "The verdict found material drift from the approved design; a human resolution is required.")
      when IntentConformanceVerdict::OUTCOME_UNCERTAIN
        blocker(REASON_UNCERTAIN, "The verdict could not reliably establish conformance; a human resolution is required.")
      else
        blocker(REASON_NOT_EVALUATED, "The verdict was not evaluated; a human resolution is required.")
      end
    end

    def blocker(reason_code, message)
      Blocker.new(reason_code:, message:)
    end
  end
end
