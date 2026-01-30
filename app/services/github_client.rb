# frozen_string_literal: true

require "octokit"
require "faraday/retry"

# GitHub API client wrapper with error handling and rate limit awareness.
#
# @example Basic usage
#   client = GithubClient.new(token: "ghp_...")
#   user = client.validate_token
#   repo = client.repository("owner/repo")
#
# @example From a GithubToken record
#   client = github_token.client
#   issues = client.issues("owner/repo", labels: "bug")
#
class GithubClient
  # Base error for all GitHub client errors
  class Error < StandardError; end

  # Raised when authentication fails (401)
  class AuthenticationError < Error
    def initialize(msg = "Invalid or expired GitHub token")
      super
    end
  end

  # Raised when a resource is not found (404)
  class NotFoundError < Error
    def initialize(msg = "Resource not found")
      super
    end
  end

  # Raised when rate limit is exceeded (403 with rate limit header)
  class RateLimitError < Error
    attr_reader :reset_at

    def initialize(reset_at = nil)
      @reset_at = reset_at
      msg = "GitHub API rate limit exceeded"
      msg += ". Resets at #{reset_at}" if reset_at
      super(msg)
    end
  end

  # Raised for other API errors
  class ApiError < Error
    attr_reader :status

    def initialize(message, status: nil)
      @status = status
      super(message)
    end
  end

  attr_reader :client

  # @param token [String] GitHub personal access token
  # @param options [Hash] Additional Octokit client options
  def initialize(token:, **options)
    @client = Octokit::Client.new(
      access_token: token,
      auto_paginate: false,
      **options
    )

    configure_middleware
  end

  # Validates the token and returns user information.
  #
  # @return [Hash] User info with :login, :id, :name, :email, :scopes keys
  # @raise [AuthenticationError] if the token is invalid
  # @raise [RateLimitError] if rate limit is exceeded
  # @raise [ApiError] for other API errors
  def validate_token
    handle_errors do
      response = client.user
      {
        login: response.login,
        id: response.id,
        name: response.name,
        email: response.email,
        scopes: client.scopes
      }
    end
  end

  # Fetches repository metadata.
  #
  # @param repo [String] Repository in "owner/name" format
  # @return [Sawyer::Resource] Repository data
  # @raise [NotFoundError] if the repository does not exist
  # @raise [AuthenticationError] if access is denied
  def repository(repo)
    handle_errors { client.repository(repo) }
  end

  # Lists issues for a repository.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param labels [String, Array<String>, nil] Label(s) to filter by
  # @param state [String] Issue state: "open", "closed", or "all"
  # @param options [Hash] Additional options passed to Octokit
  # @return [Array<Sawyer::Resource>] List of issues
  def issues(repo, labels: nil, state: "open", **options)
    opts = { state: state, **options }
    opts[:labels] = Array(labels).join(",") if labels
    handle_errors { client.issues(repo, opts) }
  end

  # Creates a pull request.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param base [String] The branch to merge into
  # @param head [String] The branch containing changes
  # @param title [String] Pull request title
  # @param body [String] Pull request description
  # @param options [Hash] Additional options (draft, etc.)
  # @return [Sawyer::Resource] The created pull request
  def create_pull_request(repo, base:, head:, title:, body: "", **options)
    handle_errors { client.create_pull_request(repo, base, head, title, body, **options) }
  end

  # Lists labels for a repository.
  #
  # @param repo [String] Repository in "owner/name" format
  # @return [Array<Sawyer::Resource>] List of labels
  def labels(repo)
    handle_errors { client.labels(repo) }
  end

  # Creates a label on a repository.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param name [String] Label name
  # @param color [String] Label color (hex without #)
  # @param description [String] Label description
  # @return [Sawyer::Resource] The created label
  def create_label(repo, name:, color:, description: "")
    handle_errors { client.add_label(repo, name, color, description: description) }
  end

  # Adds labels to an issue or pull request.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param number [Integer] Issue or PR number
  # @param labels [Array<String>] Label names to add
  # @return [Array<Sawyer::Resource>] Updated list of labels
  def add_labels_to_issue(repo, number, labels)
    handle_errors { client.add_labels_to_an_issue(repo, number, labels) }
  end

  # Removes a label from an issue or pull request.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param number [Integer] Issue or PR number
  # @param label [String] Label name to remove
  # @return [Array<Sawyer::Resource>] Updated list of labels
  def remove_label_from_issue(repo, number, label)
    handle_errors { client.remove_label(repo, number, label) }
  end

  # Gets the remaining rate limit.
  #
  # @return [Integer] Number of requests remaining
  def rate_limit_remaining
    client.rate_limit.remaining
  rescue Octokit::Error
    0
  end

  # Gets the rate limit reset time.
  #
  # @return [Time] When the rate limit resets
  def rate_limit_reset_at
    client.rate_limit.resets_at
  rescue Octokit::Error
    nil
  end

  # Checks if the rate limit is near exhaustion.
  #
  # @param threshold [Integer] Minimum remaining requests
  # @return [Boolean] true if remaining requests are below threshold
  def rate_limit_low?(threshold: 10)
    rate_limit_remaining < threshold
  end

  private

  def configure_middleware
    client.middleware = Faraday::RackBuilder.new do |builder|
      builder.use Faraday::Retry::Middleware,
        max: 3,
        interval: 0.5,
        interval_randomness: 0.5,
        backoff_factor: 2,
        retry_statuses: [ 429, 500, 502, 503, 504 ],
        retry_block: ->(env:, options:, retries:, exception:, will_retry_in:) {
          Rails.logger.warn(
            message: "github_client.retry",
            url: env[:url].to_s,
            retries: retries,
            will_retry_in: will_retry_in,
            exception: exception&.class&.name
          )
        }
      builder.use Octokit::Middleware::FollowRedirects
      builder.use Octokit::Response::RaiseError
      builder.adapter Faraday.default_adapter
    end
  end

  def handle_errors
    yield
  rescue Octokit::Unauthorized => e
    raise AuthenticationError, e.message
  rescue Octokit::NotFound => e
    raise NotFoundError, e.message
  rescue Octokit::TooManyRequests
    reset_at = client.rate_limit.resets_at rescue nil
    raise RateLimitError.new(reset_at)
  rescue Octokit::Forbidden => e
    if e.message.include?("rate limit")
      reset_at = client.rate_limit.resets_at rescue nil
      raise RateLimitError.new(reset_at)
    end
    raise ApiError.new(e.message, status: 403)
  rescue Octokit::Error => e
    status = e.respond_to?(:response_status) ? e.response_status : nil
    raise ApiError.new(e.message, status: status)
  end
end
