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
# - One retry only. If the fallback also fails, the wrapper surfaces the
#   primary's original error so the caller sees the same failure shape it
#   would see without a fallback configured.
# - Each fallback use is logged at warn level so the operation, error
#   class, and project context are observable.
# - Non-retryable errors (AuthenticationError, RateLimitError, 422/409/5xx)
#   propagate unchanged.
#
# Trust attribution:
# - +authenticated_login+ returns the primary's login when the primary
#   identity is on the project's trusted-user allowlist; otherwise it
#   returns the fallback's login so trust gates like
#   Tools::EditIssue#require_trusted_human_credential! evaluate the
#   credential that will actually perform the mutation.
class GithubClient::WithFallback
  attr_reader :primary, :fallback

  def initialize(primary:, fallback:, project:, logger: Rails.logger)
    @primary = primary
    @fallback = fallback
    @project = project
    @logger = logger
  end

  # Identity used by trust gates. The mutation will be performed by the
  # primary first; if it fails permission-shaped, the wrapper retries with
  # the fallback. The gate must therefore pass if EITHER credential is on
  # the project's allowlist — otherwise an app-backed project whose App
  # bot is untrusted could never issue a chat edit_issue even when the
  # fallback PAT owner is allowlisted.
  def authenticated_login
    primary_login = safe_authenticated_login(@primary)
    return primary_login if primary_login.present? && @project.trusted_github_user?(primary_login)

    fallback_login = safe_authenticated_login(@fallback)
    return fallback_login if fallback_login.present? && @project.trusted_github_user?(fallback_login)

    primary_login
  end

  def respond_to_missing?(method_name, include_private = false)
    @primary.respond_to?(method_name) || @fallback&.respond_to?(method_name) || super
  end

  def method_missing(method_name, *args, **kwargs, &block)
    @primary.public_send(method_name, *args, **kwargs, &block)
  rescue GithubClient::Error => primary_error
    raise unless retryable_permission_error?(primary_error) && @fallback

    log_fallback_use(method_name, primary_error)

    begin
      @fallback.public_send(method_name, *args, **kwargs, &block)
    rescue GithubClient::Error
      raise primary_error
    end
  end

  private

  def safe_authenticated_login(client)
    client.authenticated_login
  rescue StandardError
    nil
  end

  def retryable_permission_error?(error)
    case error
    when GithubClient::NotFoundError
      true
    when GithubClient::ApiError
      error.status == 403
    else
      false
    end
  end

  def log_fallback_use(method_name, error)
    @logger.warn(
      message: "github_client.pat_fallback_used",
      project_id: @project.id,
      operation: method_name.to_s,
      primary_error_class: error.class.name,
      primary_error_message: error.message
    )
  end
end
