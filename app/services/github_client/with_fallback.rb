# frozen_string_literal: true

# Wraps a primary + fallback GithubClient so callers transparently retry
# the fallback on permission-shaped failures (403, 404). This is the
# single place where the project's PAT push fallback is consulted at the
# REST API layer; every other call site just uses the project client and
# benefits automatically.
#
# Retry contract:
# - Only retries on permission-shaped failures:
#   * GithubClient::NotFoundError — GitHub returns 404 for resources a
#     credential cannot see; the PAT may see them.
#   * GithubClient::ApiError with status: 403 — excluding rate-limit 403s,
#     which raise GithubClient::RateLimitError instead (never retried).
#   * GitHub's statusless workflow-permission rejection, retained for
#     compatibility with callers that construct the canonical API error.
# - One retry only. If the fallback also fails, the wrapper surfaces the
#   primary's original error so the caller sees the same failure shape it
#   would see without a fallback configured.
# - Each fallback use is logged at warn level so the operation, error
#   class, and project context are observable.
# - Non-retryable errors (AuthenticationError, RateLimitError, 422/409/5xx)
#   propagate unchanged.
#
# Trust attribution:
# - +authenticated_login+ always identifies the primary credential because it
#   executes requests first.
# - Trust-gated mutations call +trusted_human_mutation_client+, which selects a
#   trusted fallback PAT only when the primary identity is not trusted.
class GithubClient::WithFallback
  attr_reader :primary, :fallback

  def initialize(primary:, fallback:, project:, logger: Rails.logger)
    @primary = primary
    @fallback = fallback
    @project = project
    @logger = logger
  end

  # @spec GITHUB-SYNC-017
  # Identity of the credential that normally executes wrapper requests.
  def authenticated_login
    safe_authenticated_login(@primary)
  end

  # @spec GITHUB-SYNC-017
  # Selects the credential for a mutation that requires human attribution.
  # The fallback is selected up front so a successful primary App request
  # cannot be authorized using the fallback PAT's identity.
  def trusted_human_mutation_client
    return self if trusted_github_user?(@primary)

    trusted_github_user?(@fallback) ? @fallback : self
  end

  def respond_to_missing?(method_name, include_private = false)
    @primary.respond_to?(method_name) || @fallback&.respond_to?(method_name) || super
  end

  def method_missing(method_name, *args, **kwargs, &block)
    @primary.public_send(method_name, *args, **kwargs, &block)
  rescue GithubClient::Error => primary_error
    raise unless retryable_permission_error?(primary_error) && @fallback

    log_fallback_use(method_name, args, primary_error)

    begin
      @fallback.public_send(method_name, *args, **kwargs, &block)
    rescue GithubClient::Error
      raise primary_error
    end
  end

  private

  def safe_authenticated_login(client)
    return unless client

    client.authenticated_login
  rescue StandardError
    nil
  end

  def trusted_github_user?(client)
    login = safe_authenticated_login(client)
    login.present? && @project.trusted_github_user?(login)
  end

  def retryable_permission_error?(error)
    case error
    when GithubClient::NotFoundError
      true
    when GithubClient::ApiError
      error.status == 403 || statusless_workflow_permission_error?(error)
    else
      false
    end
  end

  def statusless_workflow_permission_error?(error)
    error.status.nil? && error.message.include?("without `workflows` permission")
  end

  def log_fallback_use(method_name, args, error)
    @logger.warn(
      message: "github_client.pat_fallback_used",
      project_id: @project.id,
      operation: method_name.to_s,
      repo: fallback_repository(args),
      fallback_actor: safe_authenticated_login(@fallback),
      primary_error_class: error.class.name
    )
  end

  def fallback_repository(args)
    args.find { |arg| arg.is_a?(String) && arg.match?(%r{\A[^/\s]+/[^/\s]+\z}) } || @project.full_name
  end
end
