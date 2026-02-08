# frozen_string_literal: true

class WorkflowStatusesController < ApplicationController
  def show
    @project = policy_scope(Project).find(params[:project_id])
    authorize @project, :show?

    @poll_workflow = @project.workflow_states.find_by(
      temporal_workflow_id: "github-poll-#{@project.id}"
    )

    @recent_workflows = @project.workflow_states
      .where.not(workflow_type: "GitHubPoll")
      .order(created_at: :desc)
      .limit(10)
  end
end
