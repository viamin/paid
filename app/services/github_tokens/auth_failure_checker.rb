# frozen_string_literal: true

module GithubTokens
  class AuthFailureChecker
    RATE_LIMIT_PATTERNS = [
      /secondary rate limit/i,
      /rate limit exceeded/i,
      /too many requests/i,
      /retry-after/i
    ].freeze

    # Git clone / fetch authentication failures
    GIT_AUTH_PATTERNS = [
      /Authentication failed/i,
      /fatal: could not read Username/i,
      /HTTP 403(?::|\b).*(access denied|authentication failed|bad credentials|invalid credentials)/i,
      /HTTP 401/,
      /could not read Password/i,
      /Invalid credentials/i,
      /The requested URL returned error: 403/i,
      /The requested URL returned error: 401/i
    ].freeze

    # Proxy 503 responses from credential/proxy controllers
    PROXY_AUTH_PATTERNS = [
      /GitCredentials.*Project GitHub token is missing or inactive/i,
      /GithubProxy.*GitHub token not available/i,
      /Service Unavailable.*(GitHub token not available|Project GitHub token is missing or inactive)/i
    ].freeze

    # GithubClient errors
    CLIENT_AUTH_PATTERNS = [
      /GithubClient::AuthenticationError/,
      /Invalid or expired GitHub token/i,
      /Token is invalid or has been revoked/i,
      /Bad credentials/i,
      /\bUnauthorized\b/i
    ].freeze

    ALL_PATTERNS = (GIT_AUTH_PATTERNS + PROXY_AUTH_PATTERNS + CLIENT_AUTH_PATTERNS).freeze

    def self.call(...)
      new(...).call
    end

    def initialize(error_message:)
      @error_message = error_message.to_s
    end

    def call
      return nil if @error_message.blank?
      return nil if rate_limited?

      ALL_PATTERNS.find { |pattern| @error_message.match?(pattern) }
    end

    def auth_failure?
      call.present?
    end

    private

    def rate_limited?
      RATE_LIMIT_PATTERNS.any? { |pattern| @error_message.match?(pattern) }
    end
  end
end
