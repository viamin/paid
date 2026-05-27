# frozen_string_literal: true

module Projects
  class ExternalAgentRunsController < ApplicationController
    before_action :set_project

    def create
      authorize @project, :update?

      agent_run = AgentRuns::IngestExternal.call(
        project: @project,
        attributes: external_agent_run_params,
        initiating_user: current_user
      )

      render json: {
        id: agent_run.id,
        execution_origin: agent_run.execution_origin,
        external_source_key: agent_run.external_source_key,
        adoption_mode_snapshot: agent_run.adoption_mode_snapshot
      }, status: :created
    rescue ActiveRecord::RecordNotFound => e
      render json: { errors: [ e.message ] }, status: :not_found
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique, ArgumentError => e
      render json: { errors: [ e.message ] }, status: :unprocessable_content
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def external_agent_run_params
      params.require(:external_agent_run).permit(
        :agent_type,
        :status,
        :goal,
        :focus,
        :custom_prompt,
        :issue_id,
        :source_pull_request_number,
        :started_at,
        :completed_at,
        :duration_seconds,
        :tokens_input,
        :tokens_output,
        :cost_cents,
        :pull_request_url,
        :pull_request_number,
        :result_commit_sha,
        :external_source_key,
        :external_run_key,
        external_metadata: {}
      )
    end
  end
end
