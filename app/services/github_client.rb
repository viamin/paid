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

  # Lists repositories the token has push access to.
  # Filters by permissions.push to exclude repos where the token only
  # has metadata access (relevant for fine-grained PATs with selected repos).
  #
  # Note: GitHub's API does not expose fine-grained PAT repository scoping
  # on read operations, so this returns all repos the user has push access to
  # regardless of token configuration.
  #
  # @return [Array<Sawyer::Resource>] List of repositories
  # @raise [AuthenticationError] if the token is invalid
  # @raise [RateLimitError] if rate limit is exceeded
  def repositories
    handle_errors do
      original = client.auto_paginate
      client.auto_paginate = true
      repos = client.repositories
      repos.select { |r| r.permissions&.push }
    ensure
      client.auto_paginate = original
    end
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

  # Fetches a pull request by number.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param number [Integer] Pull request number
  # @return [Sawyer::Resource] Pull request data (includes .head.ref, .head.sha, .base.ref, etc.)
  # @raise [NotFoundError] if the pull request does not exist
  def pull_request(repo, number)
    handle_errors { client.pull_request(repo, number) }
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

  # Adds a comment to an issue or pull request.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param number [Integer] Issue or PR number
  # @param body [String] Comment body (Markdown supported)
  # @return [Sawyer::Resource] The created comment
  def add_comment(repo, number, body)
    handle_errors { client.add_comment(repo, number, body) }
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

  # Probes whether the token has write access to a repository by creating
  # an unreferenced git blob. This is the only reliable way to check
  # fine-grained PAT repository scoping, since read endpoints report the
  # user's permissions rather than the token's.
  #
  # Creates a small unreferenced blob object per successful probe.
  # Standard Git GC prunes these after ~2 weeks, but GitHub's backend
  # GC behavior is not documented. Results are cached per client instance
  # to avoid repeated probes.
  #
  # @param repo [String] Repository in "owner/name" format
  # @return [Boolean] true if the token can write to the repo
  def write_accessible?(repo)
    @write_access_cache ||= {}
    return @write_access_cache[repo] if @write_access_cache.key?(repo)

    client.create_blob(repo, "probe")
    @write_access_cache[repo] = true
  rescue Octokit::Forbidden, Octokit::NotFound
    @write_access_cache[repo] = false
  end

  # Fetches CI check runs for a git ref (branch, tag, or SHA).
  #
  # @param repo [String] Repository in "owner/name" format
  # @param ref [String] Git ref (branch name, tag, or SHA)
  # @return [Array<Hash>] Check runs with :name and :conclusion keys
  def check_runs_for_ref(repo, ref)
    handle_errors do
      response = client.check_runs_for_ref(repo, ref)
      response.check_runs.map { |cr| { name: cr.name, conclusion: cr.conclusion } }
    end
  end

  # Fetches conversation comments on an issue or pull request.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param number [Integer] Issue or PR number
  # @return [Array<Sawyer::Resource>] Comments (each has .user.login, .body, .created_at)
  def issue_comments(repo, number)
    handle_errors { client.issue_comments(repo, number) }
  end

  # Fetches review threads on a pull request via GraphQL.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param number [Integer] Pull request number
  # @return [Array<Hash>] Threads with :id, :is_resolved, :comments keys
  def review_threads(repo, number)
    owner, name = repo.split("/", 2)
    query = <<~GRAPHQL
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) {
            reviewThreads(first: 100) {
              nodes {
                id
                isResolved
                comments(first: 50) {
                  nodes {
                    body
                    path
                    line
                    author { login }
                  }
                }
              }
            }
          }
        }
      }
    GRAPHQL

    data = graphql_request(query, owner: owner, name: name, number: number)
    threads = data.dig("data", "repository", "pullRequest", "reviewThreads", "nodes") || []

    threads.map do |thread|
      {
        id: thread["id"],
        is_resolved: thread["isResolved"],
        comments: (thread.dig("comments", "nodes") || []).map do |c|
          { body: c["body"], path: c["path"], line: c["line"], author: c.dig("author", "login") }
        end
      }
    end
  end

  # Resolves a review thread on a pull request via GraphQL.
  #
  # @param thread_node_id [String] The GraphQL node ID of the review thread
  # @return [Hash] The response data
  def resolve_review_thread(thread_node_id)
    query = <<~GRAPHQL
      mutation($threadId: ID!) {
        resolveReviewThread(input: { threadId: $threadId }) {
          thread { id isResolved }
        }
      }
    GRAPHQL

    graphql_request(query, threadId: thread_node_id)
  end

  # Fetches reviews on a pull request.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param number [Integer] Pull request number
  # @return [Array<Hash>] Reviews with :id, :user_login, :state, :submitted_at keys
  # @raise [NotFoundError] if the pull request does not exist
  def pull_request_reviews(repo, number)
    handle_errors do
      reviews = client.pull_request_reviews(repo, number)
      reviews.map do |r|
        {
          id: r.id,
          user_login: r.user&.login,
          state: r.state,
          submitted_at: r.submitted_at
        }
      end
    end
  end

  # Replies to a review comment on a pull request.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param pull_number [Integer] Pull request number
  # @param comment_id [Integer] The ID of the review comment to reply to
  # @param body [String] Reply body (Markdown supported)
  # @return [Sawyer::Resource] The created reply
  def create_pull_request_comment_reply(repo, pull_number, comment_id, body)
    handle_errors do
      client.create_pull_request_comment_reply(repo, pull_number, body, comment_id)
    end
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

  def graphql_request(query, **variables)
    response = graphql_connection.post("/graphql") do |req|
      req.headers["Authorization"] = "token #{client.access_token}"
      req.body = { query: query, variables: variables }
    end
    response.body
  rescue Faraday::UnauthorizedError
    raise AuthenticationError
  rescue Faraday::Error => e
    raise ApiError.new(e.message)
  end

  def graphql_connection
    @graphql_connection ||= Faraday.new(url: "https://api.github.com") do |f|
      f.request :json
      f.response :json
      f.response :raise_error
      f.adapter Faraday.default_adapter
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
