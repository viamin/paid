# frozen_string_literal: true

module Inbox
  # Read-only detail projection; ordinary queue/count queries do not call it.
  # @spec STAGED-CLOSEOUT-ADOPTION-014
  class StagedCloseoutProgress
    MAX_RECORDS = 8

    def self.call(...) = new(...).call

    def initialize(issue:)
      @issue = issue.is_pull_request? ? issue.parent_issue : issue
      @issue = nil unless @issue&.project_id == issue.project_id
    end

    def call
      return [] unless issue && requirements.any?

      [ verification, audit, closure ]
    end

    private

    attr_reader :issue

    def readiness = @readiness ||= CloseoutVerifications::ClosureReadiness.new(issue:)
    def requirements = readiness.requirements
    def ready? = (@result ||= readiness.call).ready?
    def assessment = @assessment ||= PartialCloseouts::Assessment.call(issue)
    def records = @records ||= CloseoutVerifications::Evidence.records_for(issue)
    def runs = @runs ||= issue.agent_runs.where(goal: AgentRun::CLOSEOUT_VERIFICATION_GOAL, synthetic: true).order(id: :desc).limit(100).to_a
    def current_runs = requirements.filter_map { |mapping| runs.find { |run| run.closeout_mapping_id == mapping.id } }
    def current_records = current_runs.filter_map { |run| records.find { |record| record["verification_run_id"] == run.id } }

    def verification
      state = if current_runs.any? { |run| run.status == "running" }
        "current"
      elsif current_runs.any? { |run| run.status == "queued" }
        "waiting"
      elsif ready?
        "complete"
      elsif current_records.any? { |record| !record["current"] }
        "stale"
      else
        "blocked"
      end
      action = if state.in?(%w[current waiting])
        "Wait for the current verification run to finish."
      elsif ready?
        "Wait for acceptance assessment; collected evidence alone does not close the issue."
      else
        readiness.call.blockers.first&.next_action
      end
      milestone("closeout_verification", "Acceptance verification", state,
        requirements.first(MAX_RECORDS).map { |mapping| verification_evidence(mapping) }, action)
    end

    def verification_evidence(mapping)
      run = runs.find { |candidate| candidate.closeout_mapping_id == mapping.id }
      record = records.find { |candidate| candidate["verification_run_id"] == run&.id }
      { source: "closeout_verification", criterion: mapping.criterion_key.truncate(500),
        run_state: run&.status || "waiting", run_id: run&.id,
        revision: (run&.closeout_target_revision.presence || run&.base_commit_sha).to_s.truncate(250),
        environment: mapping.environment_class.presence || "isolated checkout", outcome: record&.fetch("outcome", nil),
        observed_values: observed_values(record),
        completed_at: record&.fetch("completed_at", nil), expires_at: record&.fetch("expires_at", nil) }.compact
    end

    def observed_values(record)
      values = record&.fetch("measurement_result", nil)
      values.is_a?(Hash) ? values.except("project_scope") : values
    end

    def audit
      state = if assessment.stale?
        audit_in_flight? ? "waiting" : "stale"
      elsif assessment.closeout_state == "accepted_awaiting_github_closure" && ready?
        "complete"
      else
        "blocked"
      end
      evidence = assessment.criteria.first(MAX_RECORDS).map do |criterion|
        { source: "acceptance_audit", criterion: criterion["criterion"].to_s.truncate(500),
          outcome: assessment.stale? ? "stale" : criterion["state"] }
      end
      milestone("acceptance_audit", "Acceptance audit", state, evidence,
        audit_action(state))
    end

    def audit_in_flight?
      issue.agent_runs.where(goal: "analyze_issue", status: AgentRun::AUTO_PICK_BLOCKING_STATUSES).exists?
    end

    def audit_action(state)
      return if state == "complete"
      return "Wait for the current acceptance audit to finish." if state == "waiting"
      return "Collect current required verification evidence before requesting acceptance assessment." unless ready?

      "Request a current acceptance audit covering every required criterion and remaining gap."
    end

    def closure
      state = if issue.github_state == "closed"
        "complete"
      elsif ready? && assessment.closeout_state == "accepted_awaiting_github_closure"
        "current"
      else
        "waiting"
      end
      milestone("source_closure", "Source issue closure", state,
        [ { source: "github", outcome: issue.github_state, url: issue.github_html_url } ],
        state == "complete" ? nil : "Close on GitHub only after current acceptance and the applicable closure policy permit it.")
    end

    def milestone(id, label, state, evidence, next_action)
      ProgressProjection::Milestone.new(id:, label:, state:, evidence:, next_action:)
    end
  end
end
