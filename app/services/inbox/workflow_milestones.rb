# frozen_string_literal: true

module Inbox
  # A typed, local projection for the selected Inbox entry. It deliberately
  # reads persisted scan and feature evidence; building an Inbox list never
  # invokes it, so list/count requests remain free of per-row remote calls.
  # @spec OPERATOR-INBOX-022
  class WorkflowMilestones
    SUPPORTED_KINDS = [
      Queue::MERGE_APPROVAL_KIND,
      Queue::ESCALATED_PR_KIND,
      Queue::TEST_REVIEW_PENDING_KIND
    ].freeze

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

      { current_action: milestones.find { |milestone| milestone[:current] }&.fetch(:action), milestones: milestones }
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
      feature = entry.issue.feature_intent
      return milestone("Design", "not_applicable", "Not applicable", "No linked approval-gated feature.") unless feature&.approval_gated?

      design_pr = feature.feature_intent_design_prs.order(created_at: :desc).first
      approved = feature.approved_waiting_for_merge? || feature.released?
      milestone("Design", approved ? "completed" : "blocked", approved ? "Approved" : "Approval required",
        approved ? "The linked feature design is approved." : "Implementation is waiting for the linked feature design approval.",
        revision: design_pr&.head_sha, actor: feature.approved_by&.name, url: design_pr&.github_url)
    end

    def test_milestone
      return milestone("Tests", "not_applicable", "Not applicable", "This project does not use strict TDD.") unless entry.project.tdd_mode == "strict"
      return milestone("Tests", "current", "Review tests", "The proposed tests need a human verdict before implementation can begin.",
        action: "Review the proposed tests and add paid-tests-approved or paid-test-changes-requested.", url: entry.issue.github_url) if entry.test_review_pending?

      milestone("Tests", "completed", "Approved", "Strict-TDD test review cleared before this implementation phase.", url: entry.issue.github_url)
    end

    def implementation_milestone
      return milestone("Implementation", "waiting", "Waiting", "Implementation starts after the test-review gate clears.") if entry.test_review_pending?

      milestone("Implementation", "completed", "Complete", "This pull request has reached the review-ready phase.", revision: entry.issue.last_scanned_head_sha)
    end

    def code_review_milestone
      return milestone("Code review", "waiting", "Waiting", "Code review follows implementation.") if entry.test_review_pending?

      milestone("Code review", "completed", "Complete", "The pull request is at its owner-review/merge decision.", revision: entry.issue.last_scanned_head_sha, url: entry.issue.github_url)
    end

    def owner_milestone
      return milestone("Owner approval", "waiting", "Waiting", "Owner approval follows code review.") if entry.test_review_pending?

      if stale_approval?
        milestone("Owner approval", "stale", "Stale", "A commit was added after the recorded approval.",
          action: guidance_instruction, revision: current_revision, url: entry.issue.github_url)
      elsif owner_approval_required?
        milestone("Owner approval", "current", "Review required", "The current revision needs owner approval.",
          action: guidance_instruction, revision: current_revision, url: entry.issue.github_url)
      else
        milestone("Owner approval", "completed", "Approved", "The current review evidence is complete.", revision: current_revision, url: entry.issue.github_url)
      end
    end

    def merge_milestone
      return milestone("Merge", "waiting", "Waiting", "Merge follows the remaining review gates.") if entry.test_review_pending?

      state = manual_merge? ? "current" : "waiting"
      label = manual_merge? ? "Your next step" : "Automatic evaluation"
      action = manual_merge? ? guidance_instruction : "Paid will reevaluate after the remaining checks and policy allow merge."
      milestone("Merge", state, label, manual_merge? ? "Approval and merge are separate actions for this project." : "Automatic merge is enabled only when all policy conditions pass.",
        action:, revision: current_revision, url: entry.issue.github_url)
    end

    def milestone(name, state, label, reason, action: nil, revision: nil, actor: nil, url: nil)
      { name:, state:, label:, reason:, action:, revision:, actor:, url:, current: state == "current" }.compact
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

    def manual_merge?
      !(guidance[:automatic_merge_active] || guidance["automatic_merge_active"])
    end

    def current_revision
      guidance.dig(:approval_evidence, "current_revision") || guidance.dig("approval_evidence", "current_revision") || entry.issue.last_scanned_head_sha
    end
  end
end
