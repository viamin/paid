# frozen_string_literal: true

module Projects
  # Captures the control state that already has a local representation before
  # ignored mode stops treating GitHub labels as instructions.  It is safe to
  # retry: each update is an assignment to the label-derived value, never a
  # toggle.  Other control representations are introduced by #4252.
  # @spec LABEL-INTEGRATION-005 LABEL-INTEGRATION-007
  class ImportLabelControlState
    Result = Data.define(:paused, :escalated)

    def self.call(...) = new(...).call

    def initialize(project:)
      @project = project
    end

    def call
      Result.new(paused: import_pauses, escalated: import_escalations)
    end

    private

    attr_reader :project

    def import_pauses
      project.issues.where(github_state: "open").find_each.count do |issue|
        next false unless issue.has_label?(Issue::PAUSED_LABEL)
        next false if issue.paused?

        issue.update_columns(paused: true, paused_at: Time.current, updated_at: Time.current)
        true
      end
    end

    def import_escalations
      project.issues.pull_requests_only.where(github_state: "open").find_each.count do |issue|
        next false unless issue.has_label?(Issue::ESCALATED_LABEL)
        next false if issue.escalated_phase?

        issue.update_columns(pr_review_phase: "escalated", pr_escalation_started_at: Time.current, updated_at: Time.current)
        true
      end
    end
  end
end
