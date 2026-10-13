# frozen_string_literal: true

module Issues
  # @spec LABEL-CONTROL-007 — Single owner of the Paid-local per-item
  # activation transition. Used by:
  #   * Projects::AgentRunsController#create_agent_run — manual run creation
  #   * Mcp::Tools::TriggerAgentRun — MCP trigger_agent_run
  #   * the projects page / Issue control_state toggle, via Issues::UpdateControlState
  # In ignored mode the activation state is the per-item "is this Paid's
  # to work on?" signal that replaces the activation label; the call is a
  # no-op in read_write/read_only because the activation label already
  # carries the same intent.
  class ActivatePaid
    def self.call(...)
      new(...).call
    end

    def initialize(project:, issue: nil, pull_request_number: nil)
      @project = project
      @issue = issue
      @pull_request_number = pull_request_number
    end

    def call
      return :noop unless @project.paid_local_activation?

      target = resolved_target
      return :noop if target.nil?
      return :noop if target.paid_activated?

      target.paid_activate!
      :activated
    rescue ActiveRecord::RecordInvalid
      :noop
    end

    private

    attr_reader :project, :issue, :pull_request_number

    def resolved_target
      return issue if issue&.persisted?
      return nil if pull_request_number.blank?

      project.issues.find_by(github_number: pull_request_number, is_pull_request: true)
    end
  end
end
