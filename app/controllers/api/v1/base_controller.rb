# frozen_string_literal: true

module Api
  module V1
    class BaseController < ActionController::API
      include Pundit::Authorization

      around_action :with_bearer_context
      rescue_from Pundit::NotAuthorizedError, with: :render_forbidden
      rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

      private

      attr_reader :current_access_token

      def current_user
        Current.user
      end

      def with_bearer_context
        token = PersonalAccessToken.authenticate(bearer_token)
        return render_unauthorized unless token&.active?

        @current_access_token = token
        TenantContext.with(token.account) do
          Current.user = token.user
          token.touch_last_used!
          yield
        ensure
          Current.reset
        end
      end

      def require_scope!(scope)
        raise Pundit::NotAuthorizedError unless current_access_token.allows?(scope)
      end

      def render_error(code, message, status)
        render json: { error: { code:, message:, details: {} } }, status:
      end

      def render_unauthorized
        render_error("unauthorized", "Authentication credentials are invalid.", :unauthorized)
      end

      def render_forbidden
        render_error("forbidden", "You are not authorized to perform this action.", :forbidden)
      end

      def render_not_found
        render_error("not_found", "The requested resource was not found.", :not_found)
      end

      def bearer_token
        request.authorization.to_s[/\ABearer (.+)\z/, 1]
      end
    end
  end
end
