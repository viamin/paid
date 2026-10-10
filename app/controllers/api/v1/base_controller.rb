# frozen_string_literal: true

module Api
  module V1
    class BaseController < ActionController::API
      include Pundit::Authorization

      around_action :with_bearer_context
      before_action :enforce_account_status!
      rescue_from Pundit::NotAuthorizedError, with: :render_forbidden
      rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

      private

      attr_reader :current_access_token

      def current_user
        Current.user
      end

      def current_account
        Current.account
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

      # API-safe equivalent of TenantEnforcement#enforce_tenant_status
      # (app/controllers/concerns/tenant_enforcement.rb), which this
      # ActionController::API subclass does not inherit: a deactivated
      # account's token is rejected outright, and a suspended account
      # keeps read access but loses write access.
      # @spec RAILS-CONTROL-PLANE-006
      def enforce_account_status!
        return unless current_account

        if current_account.deactivated?
          render_unauthorized
        elsif current_account.suspended? && mutating_request?
          render_error("forbidden", "This account is suspended. Write operations are disabled.", :forbidden)
        end
      end

      def mutating_request?
        !request.get? && !request.head?
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
