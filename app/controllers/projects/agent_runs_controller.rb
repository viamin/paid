# frozen_string_literal: true

module Projects
  class AgentRunsController < ApplicationController
    before_action :set_project
    before_action :set_agent_run, only: [ :show, :retry ]

    def index
      authorize @project, :show?
      base_scope = @project.agent_runs
      @q = base_scope.ransack(params[:q])
      @q.sorts = "created_at desc" if @q.sorts.empty?
      @pagy, @agent_runs = pagy(@q.result)
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
      issue = resolve_issue
      source_pr_number = resolve_pull_request

      unless issue || custom_prompt || source_pr_number
        redirect_to new_project_agent_run_path(@project),
          alert: "Please select an issue, provide a custom prompt, or select a pull request."
        return
      end

      create_agent_run(
        issue: issue,
        custom_prompt: custom_prompt,
        source_pull_request_number: source_pr_number
      )

      ProcessRunQueueJob.perform_later

      notice = if AgentRun.has_run_capacity? && AgentRun.queued.count <= 1
        "Agent run created and will start momentarily."
      else
        "Agent run queued. It will start automatically when a slot opens."
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

    def retry
      authorize @agent_run

      unless @agent_run.finished?
        redirect_to project_agent_run_path(@project, @agent_run),
          alert: "Only finished runs can be retried."
        return
      end

      new_run = AgentRun.create!(
        project: @project,
        issue: @agent_run.issue,
        agent_type: @agent_run.agent_type,
        custom_prompt: @agent_run.custom_prompt,
        source_pull_request_number: @agent_run.source_pull_request_number,
        goal: @agent_run.goal,
        trigger_type: "manual",
        status: "queued"
      )

      @agent_run.retry!

      ProcessRunQueueJob.perform_later

      redirect_to project_agent_run_path(@project, new_run),
        notice: "Agent run queued as a retry of run ##{@agent_run.id}."
    rescue ActiveRecord::RecordNotUnique => e
      alert = if e.cause&.message&.include?("proxy_token")
        "An unexpected error occurred. Please try again."
      else
        "An agent run is already queued or in progress for this issue."
      end
      redirect_to project_agent_run_path(@project, @agent_run), alert: alert
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def set_agent_run
      @agent_run = @project.agent_runs.find(params[:id])
    end

    def resolve_issue
      return nil if params[:issue_id].blank?

      @project.issues.find(params[:issue_id])
    end

    def resolve_pull_request
      return nil if params[:pull_request_id].blank?

      pr = @project.issues.pull_requests_only.find(params[:pull_request_id])
      pr.github_number
    end

    def create_agent_run(issue: nil, custom_prompt: nil, source_pull_request_number: nil)
      agent_type = params[:agent_type].presence || "claude_code"
      agent_type = "claude_code" unless AgentRun::AGENT_TYPES.include?(agent_type)

      goal = params[:goal].presence || "create_pr"
      goal = "create_pr" unless AgentRun::GOALS.include?(goal)

      AgentRun.create!(
        project: @project,
        issue: issue,
        agent_type: agent_type,
        custom_prompt: custom_prompt,
        source_pull_request_number: source_pull_request_number,
        goal: goal,
        trigger_type: "manual",
        status: "queued"
      )
    end
  end
end
