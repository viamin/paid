# frozen_string_literal: true

module Automation
  class Decision < Data.define(:type, :payload)
    class << self
      def noop
        new(type: "noop", payload: {})
      end

      def queue_create_pr_run(issue_id:, source_pull_request_number: nil, focus: nil,
        count_toward_draft_review_round: false, expected_draft_review_count: nil)
        new(type: "queue_create_pr_run", payload: {
          issue_id: issue_id,
          source_pull_request_number: source_pull_request_number,
          focus: focus,
          count_toward_draft_review_round: count_toward_draft_review_round,
          expected_draft_review_count: expected_draft_review_count
        }.compact)
      end

      def queue_review_run(issue_id:, source_pull_request_number:, focus: nil)
        new(type: "queue_review_run", payload: {
          issue_id: issue_id,
          source_pull_request_number: source_pull_request_number,
          focus: focus
        }.compact)
      end

      def start_planning(issue_id:)
        new(type: "start_planning", payload: { issue_id: issue_id })
      end

      def request_review(pr_number:, reviewers:)
        new(type: "request_review", payload: {
          pr_number: pr_number,
          reviewers: reviewers
        })
      end

      def dispatch_claude_review(pr_number:)
        new(type: "dispatch_claude_review", payload: {
          pr_number: pr_number
        })
      end

      def mark_ready(issue_id:, pr_number:, owner_reviewer_login: nil)
        new(type: "mark_ready", payload: {
          issue_id: issue_id,
          pr_number: pr_number,
          owner_reviewer_login: owner_reviewer_login
        }.compact)
      end

      def mark_draft(issue_id:, pr_number:)
        new(type: "mark_draft", payload: {
          issue_id: issue_id,
          pr_number: pr_number
        })
      end

      def escalate(issue_id:, pr_number:, owner_reviewer_login: nil, reason: nil)
        new(type: "escalate", payload: {
          issue_id: issue_id,
          pr_number: pr_number,
          owner_reviewer_login: owner_reviewer_login,
          reason: reason
        }.compact)
      end

      def dismiss_escalation(issue_id:, draft: nil)
        new(type: "dismiss_escalation", payload: { issue_id: issue_id, draft: draft }.compact)
      end

      def merge(issue_id:, pr_number:)
        new(type: "merge", payload: {
          issue_id: issue_id,
          pr_number: pr_number
        })
      end

      def record_pr_followup(issue_id:, labels_to_remove:, expected_followup_count:)
        new(type: "record_pr_followup", payload: {
          issue_id: issue_id,
          labels_to_remove: labels_to_remove,
          expected_followup_count: expected_followup_count
        })
      end

      def record_review_goal_retry(issue_id:, expected_review_goal_retry_count:)
        new(type: "record_review_goal_retry", payload: {
          issue_id: issue_id,
          expected_review_goal_retry_count: expected_review_goal_retry_count
        })
      end

      def queue_analyze_issue_run(issue_id:)
        new(type: "queue_analyze_issue_run", payload: { issue_id: issue_id })
      end
    end

    def to_h
      serialized_payload = payload.reject do |key, value|
        key == :count_toward_draft_review_round && value == false
      end

      { type: type }.merge(serialized_payload)
    end
  end
end
