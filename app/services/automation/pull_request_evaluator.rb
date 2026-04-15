# frozen_string_literal: true

module Automation
  class PullRequestEvaluator
    include LabelPolicy

    FOLLOWUP_TRIGGER_TYPES = %w[
      ci_failure review_threads conversation_comments changes_requested
      actionable_labels merge_conflicts review_bot_comments review_bot_threads
    ].freeze

    def initialize(record:, explicit_pr_decisions: false)
      @record = record
      @project = record.project
      @explicit_pr_decisions = explicit_pr_decisions
    end

    def call(scan: nil)
      return explicit_scan_decisions(scan) if explicit_pr_decisions

      label_decision_for(project, record)
    end

    private

    attr_reader :record, :project, :explicit_pr_decisions

    def explicit_scan_decisions(scan)
      return Result.noop unless scan

      scan = scan.deep_symbolize_keys
      trigger_types = scan.fetch(:triggers, []).map { |trigger| trigger[:type] }

      decisions =
        if trigger_types.include?("escalate_to_owner")
          [ escalate_decision(scan) ]
        elsif trigger_types.include?("dismiss_escalation")
          [ Decision.dismiss_escalation(issue_id: record.id) ]
        elsif trigger_types.include?("owner_approved")
          [ Decision.merge(issue_id: record.id, pr_number: scan[:pr_number]) ]
        elsif trigger_types.include?("review_goal_retry")
          review_goal_retry_decisions(scan, trigger_types)
        elsif trigger_types.include?("ready_for_owner")
          ready_for_owner_decisions(scan)
        elsif trigger_types.include?("paid_agent_review_pending")
          paid_agent_review_pending_decisions(scan, trigger_types)
        elsif trigger_types.include?("review_bot_review_pending")
          review_bot_review_pending_decisions(scan, trigger_types)
        elsif trigger_types.include?("manual_review_pending") || trigger_types.include?("ci_action_pending")
          non_bot_review_pending_decisions(scan, trigger_types)
        else
          standard_followup_decisions(scan)
        end

      Result.new(decisions: decisions.presence || [ Decision.noop ])
    end

    def ready_for_owner_decisions(scan)
      decisions = []
      decisions << queue_review_run_decision(scan) if trigger_present?(scan, "paid_agent_review_pending") && !paid_agent_active?(scan)
      decisions << Decision.mark_ready(
        issue_id: record.id,
        pr_number: scan[:pr_number],
        owner_reviewer_login: scan[:owner_reviewer_login]
      )
      decisions
    end

    def paid_agent_review_pending_decisions(scan, trigger_types)
      decisions = []
      decisions << queue_review_run_decision(scan) unless paid_agent_active?(scan)

      other_triggers = trigger_types - [ "paid_agent_review_pending" ]
      decisions.concat(followup_decisions(scan)) if other_triggers.any?
      decisions
    end

    def review_bot_review_pending_decisions(scan, trigger_types)
      decisions = []
      decisions << review_bot_request_decision(scan)

      other_triggers = trigger_types - [ "review_bot_review_pending" ]
      decisions.concat(followup_decisions(scan)) if other_triggers.any?
      decisions.compact
    end

    def non_bot_review_pending_decisions(scan, trigger_types)
      decisions = []

      manual_trigger = trigger(scan, "manual_review_pending")
      if manual_trigger&.dig(:reviewer_login).present?
        decisions << Decision.request_review(
          pr_number: scan[:pr_number],
          reviewers: [ manual_trigger[:reviewer_login] ]
        )
      end

      other_triggers = trigger_types - %w[manual_review_pending ci_action_pending]
      decisions.concat(followup_decisions(scan)) if other_triggers.any?
      decisions
    end

    def review_goal_retry_decisions(scan, trigger_types)
      decisions = [
        Decision.record_review_goal_retry(
          issue_id: record.id,
          expected_review_goal_retry_count: scan[:current_review_goal_retry_count]
        ),
        queue_review_run_decision(scan)
      ]

      if trigger_types.include?("ready_for_owner")
        decisions.concat(ready_for_owner_decisions(without_trigger(scan, "paid_agent_review_pending")))
        return decisions
      end

      manual_trigger = trigger(scan, "manual_review_pending")
      if manual_trigger&.dig(:reviewer_login).present?
        decisions << Decision.request_review(
          pr_number: scan[:pr_number],
          reviewers: [ manual_trigger[:reviewer_login] ]
        )
      end

      if followup_triggers?(scan)
        decisions.concat(followup_decisions(scan))
      else
        review_bot_decision = review_bot_request_decision(scan)
        decisions << review_bot_decision if review_bot_decision
      end

      decisions
    end

    def standard_followup_decisions(scan)
      followup_decisions(scan)
    end

    def followup_decisions(scan)
      if scan[:phase].in?(%w[draft restarted])
        [
          Decision.queue_create_pr_run(
            issue_id: record.id,
            source_pull_request_number: scan[:pr_number],
            count_toward_draft_review_round: true,
            expected_draft_review_count: scan[:current_draft_review_count]
          )
        ]
      else
        [
          Decision.queue_create_pr_run(
            issue_id: record.id,
            source_pull_request_number: scan[:pr_number]
          ),
          Decision.record_pr_followup(
            issue_id: record.id,
            labels_to_remove: scan[:labels_to_remove] || [],
            expected_followup_count: scan[:current_followup_count]
          )
        ]
      end
    end

    def escalate_decision(scan)
      Decision.escalate(
        issue_id: record.id,
        pr_number: scan[:pr_number],
        owner_reviewer_login: scan[:owner_reviewer_login],
        reason: trigger(scan, "escalate_to_owner")&.dig(:details)
      )
    end

    def queue_review_run_decision(scan)
      Decision.queue_review_run(issue_id: record.id, source_pull_request_number: scan[:pr_number])
    end

    def review_bot_request_decision(scan)
      login = trigger(scan, "review_bot_review_pending")&.dig(:request_login)
      return if login.blank?

      Decision.request_review(pr_number: scan[:pr_number], reviewers: [ login ])
    end

    def followup_triggers?(scan)
      scan.fetch(:triggers, []).any? { |item| FOLLOWUP_TRIGGER_TYPES.include?(item[:type]) }
    end

    def paid_agent_active?(scan)
      trigger(scan, "paid_agent_review_pending")&.dig(:active_run)
    end

    def trigger_present?(scan, type)
      trigger(scan, type).present?
    end

    def trigger(scan, type)
      scan.fetch(:triggers, []).find { |item| item[:type] == type }
    end

    def without_trigger(scan, type)
      scan.merge(triggers: scan.fetch(:triggers, []).reject { |item| item[:type] == type })
    end
  end
end
