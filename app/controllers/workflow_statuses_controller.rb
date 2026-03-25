# frozen_string_literal: true

class WorkflowStatusesController < ApplicationController
  def show
    @project = policy_scope(Project).find(params[:project_id])
    authorize @project, :show?

    @health = compute_automation_health
  end

  private

  def compute_automation_health
    unless @project.active?
      return {
        status: :inactive,
        label: "Paused",
        description: "Issue monitoring is paused. Activate the project to resume."
      }
    end

    poll_workflow = @project.workflow_states.find_by(
      temporal_workflow_id: "github-poll-#{@project.id}"
    )

    unless poll_workflow&.running?
      return {
        status: :unhealthy,
        label: "Not running",
        description: "The issue monitor is not running. " \
                     "It may be automatically restarted shortly if eligible."
      }
    end

    if @project.poll_stale_with_recheck?
      return {
        status: :stale,
        label: "Delayed",
        description: "The issue monitor appears to be behind schedule. " \
                     "It will be automatically recovered."
      }
    end

    {
      status: :healthy,
      label: "Active",
      description: "Paid is monitoring this repository for labeled issues."
    }
  end
end
