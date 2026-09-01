# frozen_string_literal: true

module Api
  module Proxy
    class KnowledgeMapController < ActionController::API
      include Api::ContainerAuthentication

      # GET /api/proxy/knowledge/map
      def show
        project = authenticated_project
        unless project
          render json: { error: "No project associated with authenticated session" }, status: :unprocessable_entity
          return
        end

        render json: Knowledge::Map::Build.call(project: project)
      end
    end
  end
end
