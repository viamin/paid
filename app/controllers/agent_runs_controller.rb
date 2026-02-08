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
    @logs = @agent_run.agent_run_logs.order(created_at: :asc).limit(500)
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

    issue = find_issue
    return unless issue

    workflow_id = start_agent_workflow(issue)

    redirect_to project_path(@project),
      notice: "Agent run started for issue ##{issue.github_number}. Workflow ID: #{workflow_id}"
  rescue Temporalio::Error::WorkflowAlreadyStartedError
    redirect_to new_project_agent_run_path(@project),
      alert: "An agent run is already in progress for this issue."
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

  def find_issue
    if params[:issue_id].present?
      @project.issues.find(params[:issue_id])
    elsif params[:issue_url].present?
      fetch_issue_from_url(params[:issue_url])
    else
      redirect_to new_project_agent_run_path(@project),
        alert: "Please select an issue or enter an issue URL."
      nil
    end
  end

  def fetch_issue_from_url(url)
    uri = begin
      URI.parse(url)
    rescue URI::InvalidURIError
      nil
    end

    unless uri&.host&.match?(/\A(www\.)?github\.com\z/)
      redirect_to new_project_agent_run_path(@project),
        alert: "Issue URL must be from #{@project.full_name}."
      return nil
    end

    match = uri.path.match(%r{\A/([^/]+)/([^/]+)/issues/(\d+)\z})
    unless match && match[1] == @project.owner && match[2] == @project.repo
      redirect_to new_project_agent_run_path(@project),
        alert: "Issue URL must be from #{@project.full_name}."
      return nil
    end

    issue_number = match[3].to_i
    issue = @project.issues.find_by(github_number: issue_number)

    if issue
      issue
    else
      redirect_to new_project_agent_run_path(@project),
        alert: "Issue ##{issue_number} not found. Issues must be synced before triggering a run."
      nil
    end
  end

  def start_agent_workflow(issue)
    agent_type = params[:agent_type].presence || "claude_code"
    unless AgentRun::AGENT_TYPES.include?(agent_type)
      agent_type = "claude_code"
    end

    handle = Paid.temporal_client.start_workflow(
      Workflows::AgentExecutionWorkflow,
      { project_id: @project.id, issue_id: issue.id, agent_type: agent_type },
      id: "manual-#{@project.id}-#{issue.id}",
      id_conflict_policy: Temporalio::WorkflowIDConflictPolicy::FAIL,
      task_queue: Paid.task_queue
    )

    Rails.logger.info(
      message: "agent_execution.manual_trigger",
      project_id: @project.id,
      issue_id: issue.id,
      workflow_id: handle.id,
      agent_type: agent_type
    )

    handle.id
  end
end
