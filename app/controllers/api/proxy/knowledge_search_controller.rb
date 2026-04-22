# frozen_string_literal: true

module Api
  module Proxy
    class KnowledgeSearchController < ActionController::API
      include Api::ContainerAuthentication

      DEFAULT_LIMIT = 5
      MAX_LIMIT = 10
      CONTENT_LIMIT = 500
      RATE_LIMIT_MAX_REQUESTS = 5
      RATE_LIMIT_PERIOD = 24.hours

      before_action :check_rate_limit

      def search
        project = @agent_run.project
        provider_config = project.knowledge_embedding_provider_configuration

        result = Knowledge::Search.call(
          project: project,
          query: params[:q].to_s,
          mode: "semantic",
          artifact_type: params[:type],
          limit: limit,
          api_key: provider_config&.api_key,
          api_base_url: provider_config&.api_base_url
        )

        render json: { results: serialize_results(result[:results]) }
      end

      private

      def check_rate_limit
        count = Rails.cache.increment(rate_limit_key, 1, expires_in: RATE_LIMIT_PERIOD)
        count ||= initialize_rate_limit_count

        if count > RATE_LIMIT_MAX_REQUESTS
          render json: { error: "Knowledge search rate limit exceeded" }, status: :too_many_requests
        end
      end

      def initialize_rate_limit_count
        Rails.cache.write(rate_limit_key, 1, expires_in: RATE_LIMIT_PERIOD)
        1
      end

      def rate_limit_key
        "agent_run:#{@agent_run.id}:knowledge_search_count"
      end

      def limit
        return DEFAULT_LIMIT if params[:limit].blank?

        params[:limit].to_i.clamp(1, MAX_LIMIT)
      end

      def serialize_results(results)
        Array(results).map do |result|
          {
            identifier: result[:identifier],
            artifact_type: result[:artifact_type],
            content: result[:content].to_s.truncate(CONTENT_LIMIT),
            scope_path: result[:scope_path],
            score: result[:score]
          }
        end
      end
    end
  end
end
