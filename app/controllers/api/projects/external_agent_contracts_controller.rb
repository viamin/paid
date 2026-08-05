# frozen_string_literal: true

module Api
  module Projects
    class ExternalAgentContractsController < ActionController::API
      include Api::ProjectInteropAuthentication

      INBOUND_AUTH_KINDS = %w[api_key signing_token].freeze

      before_action :authenticate_external_source!

      # @spec LID-RUNS-006
      def show
        render json: {
          project_id: @project.id,
          repo: @project.full_name,
          adoption_mode: @project.adoption_mode,
          external_source_key: external_source_key,
          external_execution_enabled: @project.external_execution_enabled_for?(external_source_key),
          lid: Interop::ExternalAgentLidContract.call(project: @project)
        }
      end

      private

      def authenticate_external_source!
        return if performed?

        authenticate_integration_credential!(
          external_source_key,
          auth_kinds: INBOUND_AUTH_KINDS,
          missing_message: "external_source_key is required"
        )
      end

      def external_source_key
        params[:external_source_key].to_s
      end
    end
  end
end
