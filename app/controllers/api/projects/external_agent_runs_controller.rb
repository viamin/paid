# frozen_string_literal: true

module Api
  module Projects
    class ExternalAgentRunsController < ActionController::API
      include Api::ProjectInteropAuthentication

      INBOUND_AUTH_KINDS = %w[api_key signing_token].freeze

      before_action :authenticate_external_source!

      def create
        agent_run = AgentRuns::IngestExternal.call(
          project: @project,
          attributes: external_agent_run_params
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

      def authenticate_external_source!
        return if performed?

        service_key = external_agent_run_params[:external_source_key].to_s
        if service_key.blank?
          render json: { errors: [ "external_source_key is required" ] }, status: :unprocessable_content
          return
        end

        credentials = integration_credentials_for(service_key, auth_kinds: INBOUND_AUTH_KINDS)

        if credentials.blank?
          render json: { errors: [ "No active integration credential configured for #{service_key.presence || "this source"}" ] }, status: :unauthorized
          return
        end

        provided_token = bearer_token || request.headers["X-Api-Key"].presence
        return if credentials.any? { |credential| secure_token_match?(provided_token, credential.secret) }

        render json: { errors: [ "Invalid integration credential" ] }, status: :unauthorized
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
          :external_run_key
        )
          .to_h
          .merge(external_metadata: raw_external_metadata)
      end

      def raw_external_metadata
        metadata = params.require(:external_agent_run).to_unsafe_h["external_metadata"]
        metadata.is_a?(Hash) ? metadata : {}
      end
    end
  end
end
