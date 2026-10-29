# frozen_string_literal: true

# Typed, local-only workflow status for selected Inbox detail surfaces.
# It intentionally consumes stored facts only: queue/list construction must
# remain cheap and must never make remote calls merely to decorate a row.
# @spec OPERATOR-INBOX-023
module Inbox
  class WorkflowProjection
    STATES = %w[completed current waiting blocked stale not_applicable unknown].freeze

    Result = Struct.new(:milestones, keyword_init: true) do
      def current
        milestones.find { |milestone| milestone[:state] == "current" } ||
          milestones.find { |milestone| milestone[:state].in?(%w[blocked stale waiting unknown]) }
      end

      def to_h
        { milestones:, current: }
      end
    end

    def self.call(...)
      new(...).call
    end

    def initialize(issue:)
      @issue = issue
    end

    def call
      Result.new(milestones: [ design, test_review, implementation, code_review, owner_approval, merge ])
    end

    private

    attr_reader :issue

    def design
      # Detail callers that have feature context preload it. Do not turn an
      # ordinary selected Inbox request into an extra feature lookup merely to
      # decorate the pane; absent preloaded evidence is explicitly unknown.
      return milestone("design", "Design", "unknown", "Linked design status is unavailable.") unless issue.association(:feature_intent).loaded?

      feature = issue.feature_intent
      return milestone("design", "Design", "not_applicable", "No linked feature design.") unless feature

      if feature.approved_design_revision.present? || feature.released?
        milestone("design", "Design", "completed", "Linked feature design is approved.", revision: feature.approved_design_revision, actor: feature.approved_by&.name)
      elsif feature.approval_gated?
        milestone("design", "Design", "current", "Approve the linked feature design.", actor: "feature owner")
      else
        milestone("design", "Design", "waiting", "The linked feature design is still being prepared.")
      end
    end

    def test_review
      state = issue.effective_tdd_review_state
      return milestone("test_review", "Tests", "not_applicable", "This pull request has no TDD test-review gate.") unless state
      return milestone("test_review", "Tests", "completed", "Tests were approved.", revision: issue.tdd_review_approved_at&.iso8601) if state == "approved"

      if state == "ready_for_review"
        milestone("test_review", "Tests", "current", "Approve or request changes to the tests on GitHub.", actor: "test reviewer")
      else
        milestone("test_review", "Tests", "blocked", "Test review needs changes before implementation can continue.")
      end
    end

    def implementation
      return milestone("implementation", "Implementation", "completed", "The pull request is merged.") if issue.merged_phase?
      return milestone("implementation", "Implementation", "blocked", "Implementation is escalated and needs recovery.") if issue.escalated_phase?
      return milestone("implementation", "Implementation", "completed", "Implementation is ready for review.") if issue.ready_phase?
      return milestone("implementation", "Implementation", "waiting", "Implementation is waiting for test review.") if issue.effective_tdd_review_state == "ready_for_review"
      return milestone("implementation", "Implementation", "waiting", "Implementation is in progress.") if issue.draft_phase?

      milestone("implementation", "Implementation", "unknown", "Implementation state is unavailable.")
    end

    def code_review
      return milestone("code_review", "Code review", "not_applicable", "No review assessment has been recorded.") unless assessment?
      return milestone("code_review", "Code review", "blocked", blocker_message("checks_green", "Checks or review requirements are blocking this pull request.")) if blocker?("checks_green")

      milestone("code_review", "Code review", "completed", "Code review requirements are satisfied.")
    end

    def owner_approval
      return milestone("owner_approval", "Owner approval", "stale", blocker_message("reviews_fresh", "Approval is stale for the current revision."), revision: issue.last_scanned_head_sha, actor: "owner") if blocker?("reviews_fresh")
      return milestone("owner_approval", "Owner approval", "current", blocker_message("owner_approved", "Approve the current pull request revision on GitHub."), actor: "owner") if blocker?("owner_approved")
      return milestone("owner_approval", "Owner approval", "completed", "Owner approval is current.", revision: issue.last_scanned_head_sha) if assessment?

      milestone("owner_approval", "Owner approval", "unknown", "Approval has not been assessed.")
    end

    def merge
      return milestone("merge", "Merge", "completed", "The pull request is merged.") if issue.merged_phase?
      if issue.project.auto_merge_mode == "off"
        state = approval_ready? ? "current" : "waiting"
        action = approval_ready? ? "Merge this pull request on GitHub." : "Merge is waiting for the outstanding review gates."
        return milestone("merge", "Merge", state, action, actor: "repository maintainer")
      end

      milestone("merge", "Merge", "waiting", "Automatic merge will run after all remaining gates pass.")
    end

    def milestone(key, label, state, next_action, revision: nil, actor: nil)
      { key:, label:, state:, next_action:, evidence: evidence_for(key), revision:, actor:, url: issue.github_url }.compact
    end

    def assessment?
      issue.auto_merge_evaluated_at.present? && issue.auto_merge_blockers.is_a?(Hash)
    end

    def blockers
      assessment? ? issue.auto_merge_blockers.deep_stringify_keys.fetch("failed", []) : []
    end

    def blocker?(signal)
      blockers.any? { |blocker| blocker["signal"] == signal }
    end

    def blocker_message(signal, fallback)
      blockers.find { |blocker| blocker["signal"] == signal }&.fetch("next_action", fallback) || fallback
    end

    def approval_ready?
      assessment? && !blocker?("owner_approved") && !blocker?("reviews_fresh") && !blocker?("checks_green")
    end

    def evidence_for(key)
      return blockers.select { |blocker| blocker["signal"].in?(%w[owner_approved reviews_fresh checks_green]) } if key.in?(%w[code_review owner_approval])

      []
    end
  end
end
