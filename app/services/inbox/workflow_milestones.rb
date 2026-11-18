# frozen_string_literal: true

module Inbox
  # A typed, local projection for the selected Inbox entry. It deliberately
  # reads persisted scan and feature evidence; building an Inbox list never
  # invokes it, so list/count requests remain free of per-row remote calls.
  # @spec OPERATOR-INBOX-024
  class WorkflowMilestones
    SUPPORTED_KINDS = [
      Queue::MERGE_APPROVAL_KIND,
      Queue::ESCALATED_PR_KIND,
      Queue::TEST_REVIEW_PENDING_KIND
    ].freeze
    UNBLOCK_ACTION = "Unblock this pull request."
    REAPPROVE_ACTION = "Re-approve this pull request on GitHub."

    def self.call(entry)
      new(entry).call
    end

    def self.supported?(entry)
      SUPPORTED_KINDS.include?(entry.kind) && entry.issue&.is_pull_request?
    end

    def initialize(entry)
      @entry = entry
    end

    def call
      return empty unless self.class.supported?(entry)

      actions = milestones.select { |milestone| milestone[:current] }.filter_map { |milestone| milestone[:action] }.uniq
      { current_action: actions.first, current_actions: actions, milestones: milestones }
    end

    private

    attr_reader :entry

    def empty
      { current_action: nil, milestones: [] }
    end

    def milestones
      @milestones ||= [ design_milestone, test_milestone, implementation_milestone, code_review_milestone, owner_milestone, merge_milestone ].compact
    end

    def design_milestone
      projected_milestone("design_approval", "Design")
    end

    def test_milestone
      return milestone("Tests", "current", "Review tests", "The proposed tests need a human verdict before implementation can begin.",
        action: "Review the proposed tests and add paid-tests-approved or paid-test-changes-requested.", url: entry.issue.github_url) if entry.test_review_pending?
      return milestone("Tests", "not_applicable", "Not applicable", "This project does not use strict TDD.") unless entry.project.tdd_mode == "strict"

      projected_milestone("test_review", "Tests")
    end

    def implementation_milestone
      return milestone("Implementation", "waiting", "Waiting", "Implementation starts after the test-review gate clears.") if entry.test_review_pending?
      if stalled_execution?
        return milestone("Implementation", "blocked", "Recovery required", "Paid has not confirmed that implementation reached review readiness.",
          action: guidance_instruction, revision: current_revision, url: entry.issue.github_url, current: true)
      end

      projected_milestone("implementation", "Implementation")
    end

    def code_review_milestone
      return milestone("Code review", "waiting", "Waiting", "Code review follows implementation.") if entry.test_review_pending?
      return milestone("Code review", "waiting", "Waiting", "Code review follows recovery of the stalled implementation.") if stalled_execution?
      return blocked_code_review_milestone if blocked_escalation?

      projected_milestone("code_review", "Code review")
    end

    def owner_milestone
      return milestone("Owner approval", "waiting", "Waiting", "Owner approval follows code review.") if entry.test_review_pending?
      return milestone("Owner approval", "waiting", "Waiting", "Owner approval follows implementation recovery and code review.") if stalled_execution?
      return milestone("Owner approval", "waiting", "Waiting", "Owner approval follows recovery of the escalated pull request.") if blocked_escalation?
      return reapproval_milestone if awaiting_approval_escalation?

      if stale_approval?
        milestone("Owner approval", "stale", "Stale", "A commit was added after the recorded approval.",
          action: guidance_instruction, revision: current_revision, url: entry.issue.github_url, current: true)
      elsif owner_approval_required?
        milestone("Owner approval", "current", "Review required", "The current revision needs owner approval.",
          action: guidance_instruction, revision: current_revision, url: entry.issue.github_url)
      else
        projected_milestone("owner_approval", "Owner approval")
      end
    end

    def merge_milestone
      return milestone("Merge", "waiting", "Waiting", "Merge follows the remaining review gates.") if entry.test_review_pending?
      return milestone("Merge", "waiting", "Waiting", "Merge follows recovery and the remaining review gates.") if stalled_execution?
      return milestone("Merge", "waiting", "Waiting", "Merge follows recovery and the remaining review gates.") if entry.escalated_pr?
      if stale_approval? || owner_approval_required?
        return milestone("Merge", "waiting", "Waiting", "Merge follows current-revision owner approval.")
      end

      unless authoritative.milestones.find { |item| item.id == "merge" }.state.in?(%w[current waiting])
        return projected_milestone("merge", "Merge")
      end

      state = manual_merge? ? "current" : "waiting"
      label = manual_merge? ? "Your next step" : "Automatic evaluation"
      action = manual_merge? ? guidance_instruction : "Paid will reevaluate after the remaining checks and policy allow merge."
      milestone("Merge", state, label, manual_merge? ? "Approval and merge are separate actions for this project." : "Automatic merge is enabled only when all policy conditions pass.",
        action:, actor: manual_merge? ? "Repository maintainer" : "Paid", revision: current_revision, url: entry.issue.github_url)
    end

    def blocked_code_review_milestone
      milestone("Code review", "blocked", "Blocked", "Paid stopped working this pull request after escalation.",
        action: UNBLOCK_ACTION, revision: current_revision, url: entry.issue.github_url, current: true)
    end

    def reapproval_milestone
      milestone("Owner approval", "current", "Re-approval required", "This escalated pull request is waiting on owner approval.",
        action: REAPPROVE_ACTION, revision: current_revision, url: entry.issue.github_url)
    end

    # Approval facts come from the revision-aware source shared with progress
    # API/chat. Entry context only adds recovery/test-review actions; it never
    # turns unavailable or stale evidence into an approval.
    # @spec INBOX-PROGRESS-004 OPERATOR-INBOX-024
    def authoritative
      @authoritative ||= ProgressProjection.call(issue: entry.issue)
    end

    def projected_milestone(id, name)
      item = authoritative.milestones.find { |candidate| candidate.id == id }
      state = item.state == "complete" ? "completed" : item.state
      label = if item.state == "complete"
        id.in?(%w[design_approval test_review owner_approval]) ? "Approved" : "Complete"
      else
        item.state.humanize
      end
      evidence = item.evidence.first || {}
      reason = item.next_action || if item.state == "not_applicable"
        "This milestone does not apply to the current project mode or work-item type."
                                   else
        "The current revision's recorded evidence satisfies this milestone."
                                   end
      milestone(name, state, label, reason, action: item.next_action, actor: item.actor,
        revision: evidence[:revision], url: evidence[:url], evidence: item.evidence, current: item.state.in?(%w[current stale]))
    end

    def milestone(name, state, label, reason, action: nil, revision: nil, actor: nil, url: nil, evidence: nil, current: state == "current")
      { name:, state:, label:, reason:, action:, revision:, actor:, url:, evidence:, current: }.compact
    end

    def guidance
      entry.guidance || {}
    end

    def guidance_instruction
      guidance[:instruction] || guidance["instruction"] || blockers.first&.fetch("next_action", nil) || "Review this pull request on GitHub."
    end

    def blockers
      guidance[:blockers] || guidance["blockers"] || []
    end

    def owner_approval_required?
      blockers.any? { |blocker| blocker["signal"] == "owner_approved" }
    end

    def stale_approval?
      guidance[:stale_approval] || guidance["stale_approval"] || blockers.any? { |blocker| blocker["signal"] == "reviews_fresh" }
    end

    def stalled_execution?
      guidance[:stalled_execution] || guidance["stalled_execution"]
    end

    def manual_merge?
      !(guidance[:automatic_merge_active] || guidance["automatic_merge_active"])
    end

    def blocked_escalation?
      entry.escalated_pr? && !awaiting_approval_escalation?
    end

    def awaiting_approval_escalation?
      entry.escalated_pr? && entry.record&.reason == Issue::PR_ESCALATION_REASON_AWAITING_APPROVAL
    end

    def current_revision
      guidance.dig(:approval_evidence, "current_revision") || guidance.dig("approval_evidence", "current_revision") || entry.issue.last_scanned_head_sha
    end
  end
end
