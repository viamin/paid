# frozen_string_literal: true

module Inbox
  # Read-only, detail-scoped lifecycle projection. It deliberately reads the
  # records which already control delivery; queue membership and badge counts
  # never instantiate it.
  # @spec INBOX-PROGRESS-001 INBOX-PROGRESS-002 INBOX-PROGRESS-003
  class ProgressProjection
    STATES = %w[complete current waiting blocked stale not_applicable unknown].freeze
    Milestone = Data.define(:id, :label, :state, :evidence, :next_action) do
      def to_h
        { id:, label:, state:, evidence:, next_action: }.compact
      end
    end
    Result = Data.define(:operating_mode, :tdd_mode, :current_head, :milestones) do
      def to_h
        { operating_mode:, tdd_mode:, current_head:, milestones: milestones.map(&:to_h) }
      end
    end

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue
    end

    def call
      Result.new(
        operating_mode: project.operating_mode,
        tdd_mode: project.tdd_mode,
        current_head: issue.last_scanned_head_sha,
        milestones: [ design_approval, design_release, test_review, implementation, code_review, owner_approval, merge ]
      )
    end

    private

    attr_reader :issue

    def project = issue.project

    def design_approval
      return milestone("design_approval", "Design approval", "not_applicable") unless project.human_led_feature_factory?
      return milestone("design_approval", "Design approval", "unknown", next_action: "Link the feature intent and its design evidence.") unless feature_intent
      return milestone("design_approval", "Design approval", "stale", evidence: feature_evidence,
        next_action: "Review and approve the current design revision.") if stale_design?
      return milestone("design_approval", "Design approval", "complete", evidence: feature_evidence) if approved_design? || feature_intent.released?

      milestone("design_approval", "Design approval", "waiting", evidence: feature_evidence,
        next_action: "Approve the feature design revision.")
    end

    def design_release
      return milestone("design_release", "Design release", "not_applicable") unless project.human_led_feature_factory?
      return milestone("design_release", "Design release", "unknown", next_action: "Link the feature intent and its design evidence.") unless feature_intent
      return milestone("design_release", "complete", evidence: feature_evidence) if feature_intent.released?
      return milestone("design_release", "Design release", "blocked", evidence: feature_evidence,
        next_action: "Approve the current design revision.") if stale_design? || !approved_design?

      milestone("design_release", "Design release", "current", evidence: feature_evidence,
        next_action: "Merge the approved design pull request.")
    end

    def test_review
      return milestone("test_review", "Proposed-test review", "not_applicable") unless project.tdd_mode == "strict" && !design_pull_request?
      return milestone("test_review", "Proposed-test review", "unknown", next_action: "Synchronize the current pull request head.") if current_head.blank?
      return milestone("test_review", "Proposed-test review", "stale", evidence: test_review_evidence,
        next_action: "Review the proposed tests for the current revision.") if stale_test_review?
      return milestone("test_review", "Proposed-test review", "unknown",
        next_action: "Synchronize the test-review verdict for the current revision.") unless current_test_review?

      case issue.effective_tdd_review_state
      when "approved"
        milestone("test_review", "Proposed-test review", "complete", evidence: test_review_evidence)
      when "changes_requested"
        milestone("test_review", "Proposed-test review", "blocked", evidence: test_review_evidence,
          next_action: "Revise the proposed tests and submit the current revision for review.")
      when "ready_for_review"
        milestone("test_review", "Proposed-test review", "current", evidence: test_review_evidence,
          next_action: "Review the proposed tests for the current revision.")
      else
        milestone("test_review", "Proposed-test review", "unknown", next_action: "Synchronize the test-review verdict for the current revision.")
      end
    end

    def implementation
      return milestone("implementation", "Implementation", "not_applicable") if design_pull_request?
      return milestone("implementation", "Implementation", "complete", evidence: head_evidence("pr_phase")) if issue.merged_phase?
      return milestone("implementation", "Implementation", "blocked", next_action: "Resolve the requested test changes before implementation.") if test_review.state == "blocked"
      return milestone("implementation", "Implementation", "waiting", next_action: "Approve the proposed tests before implementation begins.") if project.tdd_mode == "strict" && test_review.state != "complete"
      return milestone("implementation", "Implementation", "complete", evidence: head_evidence("pr_phase")) if issue.ready_phase?
      return milestone("implementation", "Implementation", "blocked", next_action: "Resolve the pull request escalation.") if issue.escalated_phase?

      milestone("implementation", "Implementation", "current", next_action: "Complete implementation for the current pull request.")
    end

    def code_review
      return milestone("code_review", "Code review", "complete", evidence: head_evidence("pr_phase")) if issue.merged_phase?
      return milestone("code_review", "Code review", "waiting", next_action: "Finish implementation before code review.") unless issue.ready_phase?
      return milestone("code_review", "Code review", "unknown", next_action: "Wait for a current-head merge assessment.") unless current_assessment?
      return milestone("code_review", "blocked", evidence: assessment_evidence,
        next_action: "Resolve the current merge assessment blockers.") if non_approval_blockers.present?

      milestone("code_review", "Code review", "complete", evidence: assessment_evidence)
    end

    def owner_approval
      return milestone("owner_approval", "Owner approval", "complete", evidence: head_evidence("pr_phase")) if issue.merged_phase?
      return milestone("owner_approval", "Owner approval", "waiting", next_action: "Finish implementation and code review first.") unless issue.ready_phase?
      return milestone("owner_approval", "Owner approval", "unknown", next_action: "Wait for a current-head merge assessment.") unless current_assessment?
      return milestone("owner_approval", "Owner approval", "stale", evidence: assessment_evidence,
        next_action: "Review and approve the current pull request revision.") if stale_owner_approval?
      return milestone("owner_approval", "Owner approval", "current", evidence: assessment_evidence,
        next_action: "Approve the current pull request revision.") if owner_approval_required?

      milestone("owner_approval", "Owner approval", "complete", evidence: assessment_evidence)
    end

    def merge
      return milestone("merge", "Merge", "complete", evidence: head_evidence("pr_phase")) if issue.merged_phase? || issue.github_state == "closed"
      return milestone("merge", "Merge", "blocked", next_action: "Complete the earlier delivery gates.") unless code_review.state == "complete" && owner_approval.state == "complete"
      return milestone("merge", "Merge", "current", evidence: assessment_evidence,
        next_action: "Review the current changes and make the manual merge decision on GitHub.") if project.auto_merge_mode == "off"

      milestone("merge", "Merge", "waiting", evidence: assessment_evidence,
        next_action: "Paid will reevaluate the current revision for automatic merge.")
    end

    def feature_intent
      return @feature_intent if defined?(@feature_intent)

      linked_issue = issue.parent_issue || issue
      @feature_intent = FeatureIntent.linked_to_issue(linked_issue)
        .includes(:feature_intent_design_prs, :feature_intent_approval_revisions).first
    end

    def design_prs = feature_intent&.feature_intent_design_prs || []

    def approved_design?
      approval = feature_intent.feature_intent_approval_revisions.max_by(&:revision_number)
      approval.present? && design_prs.all? { |design_pr| approval.pr_heads[design_pr.pull_request_number.to_s] == design_pr.head_sha }
    end

    def stale_design?
      design_prs.any?(&:stale?) || (feature_intent.approved_at.present? && !approved_design?)
    end

    def design_pull_request?
      return @design_pull_request if defined?(@design_pull_request)

      @design_pull_request = FeatureIntentDesignPr.joins(:feature_intent)
        .exists?(feature_intents: { project_id: project.id }, pull_request_number: issue.github_number)
    end

    def current_head = issue.last_scanned_head_sha

    def current_assessment? = current_head.present? && issue.auto_merge_evaluated_at.present? && issue.auto_merge_blockers.is_a?(Hash)

    def blockers = (issue.auto_merge_blockers || {}).deep_stringify_keys

    def failed_blockers = blockers.fetch("failed", [])

    def non_approval_blockers
      failed_blockers.reject { |blocker| blocker["signal"].in?(Inbox::MergeApproval::APPROVAL_SIGNALS) }
    end

    def owner_approval_required?
      failed_blockers.any? { |blocker| blocker["signal"] == "owner_approved" }
    end

    def stale_owner_approval?
      failed_blockers.any? { |blocker| blocker["signal"] == "reviews_fresh" }
    end

    def current_test_review? = issue.effective_tdd_review_state.present? && issue.tdd_review_head_sha == current_head

    def stale_test_review? = issue.effective_tdd_review_state.present? && issue.tdd_review_head_sha.present? && issue.tdd_review_head_sha != current_head

    def feature_evidence
      design_prs.map { |design_pr| { source: "design_pull_request", revision: design_pr.head_sha, url: design_pr.github_url } }
    end

    def head_evidence(source)
      { source:, revision: current_head, url: issue.github_url }.compact
    end

    def test_review_evidence
      { source: "tdd_test_verdict", revision: issue.tdd_review_head_sha, url: issue.github_url }.compact
    end

    def assessment_evidence
      { source: "merge_assessment", revision: current_head, url: issue.github_url,
        assessed_at: issue.auto_merge_evaluated_at&.iso8601 }.compact
    end

    def milestone(id, label, state, evidence: [], next_action: nil)
      raise ArgumentError, "unknown progress state: #{state}" unless STATES.include?(state)

      Milestone.new(id:, label:, state:, evidence: Array(evidence), next_action:)
    end
  end
end
