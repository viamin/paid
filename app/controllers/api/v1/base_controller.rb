# frozen_string_literal: true

module Api
  module V1
    # Base controller for the /api/v1 mobile namespace: token-authenticated
    # only (no Devise, no cookies, no CSRF), unified error envelope, tenant
    # context from the token's account so Pundit policies decide exactly as
    # they do behind the web session path.
    class BaseController < ActionController::API
      include Pundit::Authorization

      UNAUTHORIZED_MESSAGE = "Unauthorized"

      around_action :with_bearer_request_context, prepend: true
      before_action :authenticate_bearer!
      before_action :enforce_bearer_rate_limit!
      after_action :verify_authorized, unless: :skip_pundit?
      after_action :verify_policy_scoped, if: :verify_policy_scoped?

      rescue_from Pundit::NotAuthorizedError, with: :forbidden

      private

      attr_reader :current_bearer_token

      def current_user
        Current.user
      end

      def current_account
        Current.account
      end

      def pundit_user
        current_user
      end

      # Mirrors ApplicationController#with_current_attributes minus the
      # session cookie path: tenant state is cleared after every request so
      # a pooled connection never leaks one token's account into the next.
      def with_bearer_request_context
        Current.request_id = request.uuid
        yield
      ensure
        TenantContext.clear!
        Current.reset
      end

      # Resolves Authorization: Bearer paid_pat_…, rejects anything else with
      # the generic 401 envelope, then establishes Current.user and the
      # tenant context from the token's user and account. Tokens are never
      # accepted from query parameters, cookies, or any non-header channel.
      # @spec MOBILE-API-002
      # @spec MOBILE-API-005
      def authenticate_bearer!
        token = PersonalAccessToken.resolve(bearer_token_value)
        return halt_request { render_unauthorized } if token.nil?

        Current.user = token.user
        TenantContext.apply!(token.account)
        token.touch_last_used!
        @current_bearer_token = token
      end

      # Every authenticated /api/v1 request counts against its token's
      # budget — SSE requests once at stream start, since the counter is
      # incremented per HTTP request, before the action runs.
      # @spec MOBILE-API-004
      def enforce_bearer_rate_limit!
        retry_after = Api::V1::TokenRateLimit.retry_after_if_exceeded(token_id: current_bearer_token.id)

        return if retry_after.nil?

        halt_request do
          response.headers["Retry-After"] = retry_after.to_s
          render_error(:too_many_requests, :rate_limited, "Too many requests. Slow down and retry shortly.")
        end
      end

      # Marks a request whose callback chain stopped before the action ran
      # (401/429 renders), so Pundit verification does not demand an
      # authorize call from a request that never dispatched.
      def halt_request
        @request_halted = true
        yield
      end

      def bearer_token_value
        header = request.headers["Authorization"]
        return nil unless header.is_a?(String)

        scheme, value = header.split(" ", 2)
        return nil unless scheme.to_s.casecmp("bearer").zero?

        value
      end

      # One generic message for every failure case — the API does not
      # disclose whether a token is missing, malformed, unknown, revoked, or
      # expired.
      def render_unauthorized
        render_error(:unauthorized, :unauthorized, UNAUTHORIZED_MESSAGE)
      end

      def render_error(status, code, message, details: {})
        render json: { error: { code: code, message: message, details: details } }, status: status
      end

      def forbidden
        render_error(:forbidden, :forbidden, "You are not authorized to perform this action.")
      end

      def skip_pundit?
        is_a?(Api::V1::ProbeController) || @request_halted
      end

      def verify_policy_scoped?
        action_name == "index" && !skip_pundit?
      end
    end
  end
end
