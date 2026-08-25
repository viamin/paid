# frozen_string_literal: true

module Api
  module Proxy
    class ResearchController < ActionController::API
      include Api::ContainerAuthentication

      # @spec EGRESS-POLICY-008
      # @spec EGRESS-POLICY-009
      def fetch
        AgentRuns::Research::AccessPolicy.allow!(agent_run: @agent_run)
        reject_request_body!

        render json: AgentRuns::Research::Fetcher.call(
          agent_run: @agent_run,
          url: params[:url].to_s,
          method: params[:method].to_s
        )
      rescue AgentRuns::Research::Error => error
        render json: { error: error.message }, status: error.status
      end

      # @spec EGRESS-POLICY-008
      # @spec EGRESS-POLICY-009
      def search
        AgentRuns::Research::AccessPolicy.allow!(agent_run: @agent_run)
        reject_request_body!

        render json: AgentRuns::Research::Search.call(
          agent_run: @agent_run,
          query: params[:q].to_s
        )
      rescue AgentRuns::Research::Error => error
        render json: { error: error.message }, status: error.status
      end

      private

      def reject_request_body!
        return if request.raw_post.blank?

        raise AgentRuns::Research::RequestInvalidError, "Brokered research does not accept request bodies"
      end
    end
  end
end
