# frozen_string_literal: true

class AgentRunsController < ApplicationController
  before_action :set_project
  before_action :set_agent_run, only: :show

  def index
    @agent_runs = @project.agent_runs.recent.limit(50)
    authorize @project, :show?
  end

  def show
    authorize @agent_run
    @logs = @agent_run.agent_run_logs.order(created_at: :asc).limit(500).load
  end

  def new
    authorize @project, :run_agent?
    @issues = @project.issues
      .where(github_state: "open")
      .where(paid_state: %w[new planning failed])
      .order(github_number: :desc)
  end

  def create
    authorize @project, :run_agent?

    custom_prompt = params[:custom_prompt]&.strip.presence
    issue, error = resolve_issue

    if error
      redirect_to new_project_agent_run_path(@project), alert: error
      return
    end

    unless issue || custom_prompt
      redirect_to new_project_agent_run_path(@project),
        alert: "Please select an issue, enter an issue URL, or provide a custom prompt."
      return
    end

    workflow_id = start_agent_workflow(issue: issue, custom_prompt: custom_prompt)

    notice = if issue
      "Agent run started for issue ##{issue.github_number}. Workflow ID: #{workflow_id}"
    else
      "Agent run started with custom prompt. Workflow ID: #{workflow_id}"
    end

    redirect_to project_path(@project), notice: notice
  rescue Temporalio::Error::WorkflowAlreadyStartedError
    alert_message = issue ? "An agent run is already in progress for this issue." : "An agent run is already in progress."
    redirect_to new_project_agent_run_path(@project), alert: alert_message
  rescue Temporalio::Error::RPCError => e
    redirect_to new_project_agent_run_path(@project),
      alert: "Failed to start agent run: #{e.message}"
  end

  private

  def set_project
    @project = policy_scope(Project).find(params[:project_id])
  end

  def set_agent_run
    @agent_run = @project.agent_runs.find(params[:id])
  end

  # Returns [issue, error_message]. If error_message is present, issue is nil.
  def resolve_issue
    if params[:issue_id].present?
      [ @project.issues.find(params[:issue_id]), nil ]
    elsif params[:issue_url].present?
      fetch_issue_from_url(params[:issue_url])
    else
      [ nil, nil ]
    end
  end

  def fetch_issue_from_url(url)
    uri = begin
      URI.parse(url)
    rescue URI::InvalidURIError
      nil
    end

    unless uri&.host&.match?(/\A(www\.)?github\.com\z/)
      return [ nil, "Issue URL must be a github.com URL." ]
    end

    match = uri.path.match(%r{\A/([^/]+)/([^/]+)/issues/(\d+)\z})
    unless match && match[1] == @project.owner && match[2] == @project.repo
      return [ nil, "Issue URL must be from #{@project.full_name}." ]
    end

    issue_number = match[3].to_i
    issue = @project.issues.find_by(github_number: issue_number)

    if issue
      [ issue, nil ]
    else
      [ nil, "Issue ##{issue_number} not found. Issues must be synced before triggering a run." ]
    end
  end

  def start_agent_workflow(issue: nil, custom_prompt: nil)
    agent_type = params[:agent_type].presence || "claude_code"
    agent_type = "claude_code" unless AgentRun::AGENT_TYPES.include?(agent_type)

    workflow_input = {
      project_id: @project.id,
      agent_type: agent_type,
      issue_id: issue&.id,
      custom_prompt: custom_prompt
    }.compact

    workflow_id = if issue
      "manual-#{@project.id}-#{issue.id}"
    else
      "manual-#{@project.id}-prompt-#{SecureRandom.hex(8)}"
    end

    handle = Paid.temporal_client.start_workflow(
      Workflows::AgentExecutionWorkflow,
      workflow_input,
      id: workflow_id,
      id_conflict_policy: Temporalio::WorkflowIDConflictPolicy::FAIL,
      task_queue: Paid.task_queue
    )

    Rails.logger.info(
      message: "agent_execution.manual_trigger",
      project_id: @project.id,
      issue_id: issue&.id,
      workflow_id: handle.id,
      agent_type: agent_type,
      has_custom_prompt: custom_prompt.present?
    )

    handle.id
  end
end
