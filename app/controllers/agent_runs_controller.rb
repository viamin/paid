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
      .issues_only
      .where(github_state: "open")
      .where(paid_state: %w[new planning failed])
      .order(github_number: :desc)
    @pull_requests = @project.issues
      .pull_requests_only
      .where(github_state: "open")
      .order(github_number: :desc)
  end

  def create
    authorize @project, :run_agent?

    custom_prompt = params[:custom_prompt]&.strip.presence
    issue, error = resolve_issue
    source_pr_number, pr_error = resolve_pull_request

    if error
      redirect_to new_project_agent_run_path(@project), alert: error
      return
    end

    if pr_error
      redirect_to new_project_agent_run_path(@project), alert: pr_error
      return
    end

    unless issue || custom_prompt || source_pr_number
      redirect_to new_project_agent_run_path(@project),
        alert: "Please select an issue, enter an issue URL, provide a custom prompt, or enter a pull request URL."
      return
    end

    # Always create runs as "queued" and let ProcessRunQueueJob handle starting.
    # This eliminates TOCTOU race conditions between capacity check and workflow start,
    # and provides a single consistent code path with Temporal workflows.
    create_agent_run(
      issue: issue,
      custom_prompt: custom_prompt,
      source_pull_request_number: source_pr_number
    )

    ProcessRunQueueJob.perform_later

    notice = if AgentRun.has_run_capacity?
      "Agent run created and will start momentarily."
    else
      "Agent run queued (at capacity). It will start automatically when a slot opens."
    end

    redirect_to project_path(@project), notice: notice
  rescue ActiveRecord::RecordNotUnique => e
    alert = if e.cause&.message&.include?("proxy_token")
      "An unexpected error occurred. Please try again."
    else
      "An agent run is already queued or in progress."
    end
    redirect_to new_project_agent_run_path(@project), alert: alert
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

  # Returns [pr_number, error_message]. If error_message is present, pr_number is nil.
  def resolve_pull_request
    if params[:pull_request_id].present?
      pr = @project.issues.pull_requests_only.find(params[:pull_request_id])
      [ pr.github_number, nil ]
    elsif params[:pull_request_url].present?
      fetch_pull_request_from_url(params[:pull_request_url])
    else
      [ nil, nil ]
    end
  end

  def fetch_pull_request_from_url(url)
    uri = begin
      URI.parse(url)
    rescue URI::InvalidURIError
      nil
    end

    unless uri&.host&.match?(/\A(www\.)?github\.com\z/)
      return [ nil, "Pull request URL must be a github.com URL." ]
    end

    match = uri.path.match(%r{\A/([^/]+)/([^/]+)/pull/(\d+)\z})
    unless match && match[1] == @project.owner && match[2] == @project.repo
      return [ nil, "Pull request URL must be from #{@project.full_name}." ]
    end

    [ match[3].to_i, nil ]
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

  # Creates the AgentRun record with "queued" status.
  # Capacity evaluation and workflow starts are handled by ProcessRunQueueJob,
  # ensuring a single consistent code path and eliminating TOCTOU race conditions.
  # Raises ActiveRecord::RecordNotUnique if a duplicate active run exists (enforced by DB indexes).
  def create_agent_run(issue: nil, custom_prompt: nil, source_pull_request_number: nil)
    agent_type = params[:agent_type].presence || "claude_code"
    agent_type = "claude_code" unless AgentRun::AGENT_TYPES.include?(agent_type)

    AgentRun.create!(
      project: @project,
      issue: issue,
      agent_type: agent_type,
      custom_prompt: custom_prompt,
      source_pull_request_number: source_pull_request_number,
      status: "queued"
    )
  end
end
