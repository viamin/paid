# frozen_string_literal: true

module Automation
  class WorkflowDecisionExecutor
    def self.call(workflow:, project_id:, result:)
      new(workflow:, project_id:).call(result)
    end

    def initialize(workflow:, project_id:)
      @workflow = workflow
      @project_id = project_id
    end

    def call(result)
      Array(result[:decisions]).each do |decision|
        execute(decision.deep_symbolize_keys)
      end
    end

    private

    attr_reader :workflow, :project_id

    def execute(decision)
      case decision.fetch(:type)
      when "noop"
        nil
      when "queue_create_pr_run"
        workflow.send(:queue_create_pr_run, project_id, decision)
      when "queue_review_run"
        workflow.send(:queue_review_run, project_id, decision)
      when "queue_analyze_issue_run"
        workflow.send(:run_activity, Activities::QueueAgentRunActivity, {
          project_id: project_id,
          issue_id: decision[:issue_id],
          goal: "analyze_issue"
        }, timeout: 30)
      when "start_planning"
        workflow.send(:start_planning_workflow, project_id, decision[:issue_id])
      when "request_review"
        workflow.send(:request_review, project_id, decision[:pr_number], decision[:reviewers],
          log_key: "pr_review.request_review_failed")
      when "dispatch_claude_review"
        workflow.send(:run_activity, Activities::DispatchClaudeReviewActivity, {
          project_id: project_id,
          pr_number: decision[:pr_number]
        }, timeout: 60)
      when "mark_ready"
        workflow.send(:handle_mark_ready, project_id, decision)
      when "escalate"
        workflow.send(:handle_escalate_decision, project_id, decision)
      when "dismiss_escalation"
        workflow.send(:handle_dismiss_escalation, project_id, decision)
      when "merge"
        workflow.send(:handle_owner_approved, project_id,
          issue_id: decision[:issue_id], pr_number: decision[:pr_number])
      when "record_pr_followup"
        workflow.send(:run_activity, Activities::RecordPrFollowupActivity, {
          project_id: project_id,
          issue_id: decision[:issue_id],
          labels_to_remove: decision[:labels_to_remove] || [],
          expected_followup_count: decision[:expected_followup_count]
        }, timeout: 30)
      when "record_review_goal_retry"
        workflow.send(:run_activity, Activities::RecordReviewGoalRetryActivity, {
          issue_id: decision[:issue_id],
          expected_review_goal_retry_count: decision[:expected_review_goal_retry_count]
        }, timeout: 30)
      end
    end
  end
end
