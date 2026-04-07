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
  DEFAULT_CHECK_RUNS_PER_PAGE = 100
  DEFAULT_CHECK_RUNS_MAX_PAGES = 10

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
  # @return [Hash] User info with :login, :id, :name, :email, :scopes, :expires_at keys
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
        scopes: client.scopes,
        expires_at: token_expiration_from_response
      }
    end
  end

  # Returns the login of the authenticated user (or installation actor) this
  # client is operating as. Cached per-instance because the answer does not
  # change for the lifetime of the token. Callers should treat a nil return
  # as "identity unknown" and fall back to author-agnostic behavior.
  #
  # @return [String, nil] Downcased login, or nil if lookup failed.
  def authenticated_login
    return @authenticated_login if defined?(@authenticated_login)

    @authenticated_login = handle_errors { client.user.login&.downcase }
  rescue Error
    @authenticated_login = nil
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

  # Fetches file contents from a repository.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param path [String] File path within the repository
  # @return [Sawyer::Resource] File content data (Base64-encoded)
  # @raise [NotFoundError] if the file does not exist
  # @raise [AuthenticationError] if access is denied
  def contents(repo, path:)
    handle_errors { client.contents(repo, path: path) }
  end

  # Fetches the full file tree for a repository at a given ref.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param ref [String] Git ref (branch, tag, or SHA)
  # @param recursive [Boolean] Whether to fetch the tree recursively
  # @return [Sawyer::Resource] Tree data with .tree array of items
  # @raise [NotFoundError] if the ref does not exist
  def tree(repo, ref, recursive: false)
    handle_errors { client.tree(repo, ref, recursive: recursive) }
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
      repos = with_auto_paginate { client.repositories }
      repos.select { |r| r.permissions&.push }
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

  # Lists files changed in a pull request.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param number [Integer] Pull request number
  # @return [Array<String>] File paths changed in the pull request
  def pull_request_files(repo, number)
    handle_errors do
      with_auto_paginate { client.pull_request_files(repo, number) }
    end.map(&:filename)
  end

  # Creates an issue on a repository.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param title [String] Issue title
  # @param body [String] Issue body (Markdown supported)
  # @param labels [Array<String>] Label names to add
  # @param options [Hash] Additional options passed to Octokit
  # @return [Sawyer::Resource] The created issue
  def create_issue(repo, title:, body: "", labels: [], **options)
    handle_errors { client.create_issue(repo, title, body, labels: labels, **options) }
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
  # Paginates to collect all check runs (repos with many workflows
  # or matrix builds may exceed a single page).
  #
  # @param repo [String] Repository in "owner/name" format
  # @param ref [String] Git ref (branch name, tag, or SHA)
  # @return [Array<Hash>] Check runs with :name and :conclusion keys
  def check_runs_for_ref(repo, ref)
    handle_errors do
      all_check_runs = []
      total_count = 0
      page = 1

      loop do
        response = client.check_runs_for_ref(repo, ref, per_page: DEFAULT_CHECK_RUNS_PER_PAGE, page: page)
        total_count = response.total_count
        all_check_runs.concat(response.check_runs)
        break if all_check_runs.size >= response.total_count || response.check_runs.size < DEFAULT_CHECK_RUNS_PER_PAGE

        page += 1
        break if page > DEFAULT_CHECK_RUNS_MAX_PAGES
      end

      if all_check_runs.size < total_count
        Rails.logger.warn(
          message: "github_client.check_runs_pagination_truncated",
          repo: repo,
          ref: ref,
          total_count: total_count,
          fetched_count: all_check_runs.size,
          max_pages: DEFAULT_CHECK_RUNS_MAX_PAGES
        )
      end

      all_check_runs.map do |cr|
        {
          name: cr.name,
          conclusion: cr.conclusion,
          started_at: parse_check_run_timestamp(cr.started_at),
          completed_at: parse_check_run_timestamp(cr.completed_at),
          app_id: cr.app&.id
        }
      end
    end
  end

  # Fetches all conversation comments on an issue or pull request.
  # Uses auto_paginate to collect all comments, since the default page
  # size (~30) would miss newer comments on busy PRs.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param number [Integer] Issue or PR number
  # @return [Array<Sawyer::Resource>] Comments (each has .user.login, .body, .created_at)
  def issue_comments(repo, number)
    handle_errors do
      with_auto_paginate { client.issue_comments(repo, number, per_page: 100, page: 1) }
    end
  end

  # Fetches issue timeline events such as label additions/removals.
  # Caps pagination at +max_pages+ (default 10 = 1 000 events) to avoid
  # unbounded API usage on long-lived issues.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param number [Integer] Issue or PR number
  # @param max_pages [Integer] Maximum number of pages to fetch (default: 10)
  # @return [Array<Sawyer::Resource>] Events (each may include .event, .actor.login, .label.name)
  def issue_events(repo, number, max_pages: 10)
    handle_errors do
      all_events = []
      page = 1

      loop do
        batch = client.issue_events(repo, number, per_page: 100, page: page)
        all_events.concat(Array(batch))
        break if batch.size < 100 || page >= max_pages

        page += 1
      end

      all_events
    end
  end

  # Fetches the most recent page of conversation comments. Use this for
  # idempotency checks where auto-paginating all comments is unnecessary
  # and wastes API rate limit on long-lived PRs.
  #
  # IMPORTANT: GitHub's REST `/repos/{owner}/{repo}/issues/{number}/comments`
  # endpoint always returns comments in ascending order by ID and does NOT
  # honor `sort` or `direction` params — those are only supported on the
  # repo-level `/issues/comments` endpoint. To actually get the newest
  # comments, we probe the `Link: last` header on page 1 and re-fetch the
  # final page. When there is ≤1 page of comments, the first-page response
  # is already the authoritative answer.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param number [Integer] Issue or PR number
  # @return [Array<Sawyer::Resource>] Up to 100 most-recent comments, each
  #   with .user.login, .body, .created_at. Order within the returned page
  #   is ascending by ID — callers that need a specific order must sort.
  def recent_issue_comments(repo, number)
    handle_errors do
      first_page = client.issue_comments(repo, number, per_page: 100, page: 1)
      last_rel = client.last_response&.rels&.dig(:last)
      return first_page if last_rel.nil?

      client.get(last_rel.href)
    end
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
                    pullRequestReview {
                      url
                    }
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
          {
            body: c["body"],
            path: c["path"],
            line: c["line"],
            author: c.dig("author", "login"),
            review_url: c.dig("pullRequestReview", "url")
          }
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
  # @return [Array<Hash>] Reviews with :id, :user_login, :state, :body, :submitted_at keys (:body is always a String)
  # @raise [NotFoundError] if the pull request does not exist
  def pull_request_reviews(repo, number)
    handle_errors do
      reviews = client.pull_request_reviews(repo, number)
      reviews.map do |r|
        {
          id: r.id,
          user_login: r.user&.login,
          state: r.state,
          body: r.body.to_s,
          submitted_at: parse_timestamp(r.submitted_at)
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

  # Requests review from users on a pull request.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param number [Integer] Pull request number
  # @param reviewers [Array<String>] GitHub logins to request review from
  # @return [Sawyer::Resource] The review request response
  def request_pull_request_review(repo, number, reviewers:)
    handle_errors { client.request_pull_request_review(repo, number, reviewers: reviewers) }
  end

  # Requests review from bots on a pull request via GraphQL.
  #
  # The REST API for requesting reviews silently fails for bot re-requests
  # (returns 201 but does not actually create the review request). The GraphQL
  # requestReviews mutation with botIds reliably triggers bot reviews.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param number [Integer] Pull request number
  # @param bot_node_ids [Array<String>] GraphQL node IDs of the bots (e.g. ["BOT_kgDOCnlnWA"])
  # @return [Hash] The response data
  def request_bot_review(repo, number, bot_node_ids:)
    pr_node_id = pull_request_node_id!(repo, number)

    query = <<~GRAPHQL
      mutation($pullRequestId: ID!, $botIds: [ID!]!) {
        requestReviews(input: { pullRequestId: $pullRequestId, botIds: $botIds }) {
          pullRequest { id }
        }
      }
    GRAPHQL

    response = graphql_request(query, pullRequestId: pr_node_id, botIds: bot_node_ids)

    if response["errors"].present?
      message = response["errors"].map { |e| e["message"] }.join(", ")
      status = message.match?(/unprocessable|cannot request|not available/i) ? 422 : nil
      raise ApiError.new(message, status: status)
    end

    response
  end

  # Checks pending review requests on a pull request.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param number [Integer] Pull request number
  # @return [Hash] Review requests with :users and :teams keys
  def pull_request_review_requests(repo, number)
    handle_errors do
      response = client.pull_request_review_requests(repo, number)
      {
        users: (response.users || []).map(&:login),
        teams: (response.teams || []).map(&:slug)
      }
    end
  end

  # Marks a draft pull request as ready for review via GraphQL.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param number [Integer] Pull request number
  # @return [Hash] The response data
  def mark_pull_request_ready(repo, number)
    node_id = pull_request_node_id!(repo, number)

    query = <<~GRAPHQL
      mutation($pullRequestId: ID!) {
        markPullRequestReadyForReview(input: { pullRequestId: $pullRequestId }) {
          pullRequest { id isDraft }
        }
      }
    GRAPHQL

    response = graphql_request(query, pullRequestId: node_id)

    if response["errors"].present?
      raise ApiError.new(response["errors"].map { |e| e["message"] }.join(", "))
    end

    pr_result = response.dig("data", "markPullRequestReadyForReview", "pullRequest")
    raise ApiError.new("Unexpected response from markPullRequestReadyForReview") unless pr_result

    pr_result
  end

  # Merges a pull request.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param number [Integer] Pull request number
  # @param merge_method [String] Merge method: "squash", "merge", or "rebase"
  # @param commit_title [String, nil] Custom commit title
  # @param commit_message [String, nil] Custom commit message
  # @return [Sawyer::Resource] The merge response
  def merge_pull_request(repo, number, merge_method: "squash", commit_title: nil, commit_message: nil)
    options = { merge_method: merge_method }
    options[:commit_title] = commit_title if commit_title
    options[:commit_message] = commit_message if commit_message

    path = "#{Octokit::Repository.path repo}/pulls/#{number}/merge"
    handle_errors { client.put(path, options) }
  end

  # Fetches a git reference (branch or tag).
  #
  # @param repo [String] Repository in "owner/name" format
  # @param ref [String] Reference name (e.g., "heads/main")
  # @return [Sawyer::Resource] The reference object with :object containing :sha
  def ref(repo, ref)
    handle_errors { client.ref(repo, ref) }
  end

  # Creates a git reference (branch or tag).
  #
  # @param repo [String] Repository in "owner/name" format
  # @param ref [String] Reference name (e.g., "refs/heads/feature-branch")
  # @param sha [String] SHA to point the reference at
  # @return [Sawyer::Resource] The created reference
  def create_ref(repo, ref, sha)
    handle_errors { client.create_ref(repo, ref, sha) }
  end

  # Deletes a git reference (branch or tag).
  #
  # @param repo [String] Repository in "owner/name" format
  # @param ref [String] Reference name (e.g., "heads/feature-branch")
  # @return [Boolean] true if successfully deleted
  def delete_ref(repo, ref)
    handle_errors { client.delete_ref(repo, ref) }
  end

  # Lists pull requests for a repository.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param options [Hash] Filter options (state, head, base, etc.)
  # @return [Array<Sawyer::Resource>] List of pull requests
  def pull_requests(repo, **options)
    handle_errors { client.pull_requests(repo, **options) }
  end

  # Merges a branch into another branch via the GitHub API.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param base [String] Branch to merge into
  # @param head [String] Branch to merge from
  # @param commit_message [String] Merge commit message
  # @return [Sawyer::Resource] The merge commit
  def merge(repo, base, head, commit_message: nil)
    options = { base: base, head: head }
    options[:commit_message] = commit_message if commit_message
    handle_errors { client.merge(repo, base, head, options) }
  end

  # Fetches code scanning alerts for a repository for the given state (default: "open").
  # Uses auto-pagination to get an authoritative snapshot of all alerts in the requested state.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param severity [String, nil] Filter by security severity: "low", "medium", "high", or "critical"
  # @param state [String] Alert state to filter by: "open", "dismissed", or "fixed"
  # @return [Array<Hash>] Alerts with :number, :state, :severity, :rule_id,
  #   :rule_description, :tool_name, :summary, :html_url,
  #   :created_at, :updated_at keys
  def code_scanning_alerts(repo, severity: nil, state: "open", per_page: 100)
    handle_errors do
      params = { state: state, per_page: per_page }
      params[:severity] = severity if severity.present?

      all_alerts = client.paginate(
        "#{Octokit::Repository.path(repo)}/code-scanning/alerts",
        **params
      )

      Array(all_alerts).map do |alert|
        rule = alert.rule
        tool = alert.tool

        {
          number: alert.number,
          state: alert.state,
          severity: rule&.security_severity_level,
          rule_id: rule&.id,
          rule_description: rule&.description,
          tool_name: tool&.name,
          summary: alert.most_recent_instance&.message&.text,
          html_url: alert.html_url,
          created_at: alert.created_at,
          updated_at: alert.updated_at || alert.created_at
        }
      end
    end
  end

  # Fetches reactions on a pull request (actually an issue endpoint in GitHub's API).
  #
  # @param repo [String] Repository in "owner/name" format
  # @param number [Integer] Pull request number
  # @return [Array<Hash>] Reactions with :user_login, :content keys
  #   Content values: "+1", "-1", "laugh", "confused", "heart", "hooray", "rocket", "eyes"
  def pull_request_reactions(repo, number)
    handle_errors do
      reactions = with_auto_paginate do
        client.issue_reactions(repo, number, accept: "application/vnd.github.squirrel-girl-preview+json")
      end
      reactions.map do |r|
        {
          user_login: r.user&.login,
          content: r.content,
          created_at: parse_timestamp(r.created_at)
        }
      end
    end
  end

  # Fetches reactions on an issue (same API as PR reactions).
  #
  # @param repo [String] Repository in "owner/name" format
  # @param number [Integer] Issue number
  # @return [Array<Hash>] Reactions with :user_login, :content keys
  def issue_reactions(repo, number)
    pull_request_reactions(repo, number)
  end

  # Fetches review comments (line-level comments) on a pull request.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param number [Integer] Pull request number
  # @param per_page [Integer, nil] When set, fetches a single page of this size
  #   (no auto-pagination). When nil, auto-paginates all comments.
  # @return [Array<Hash>] Comments with :id, :user_login, :body, :created_at keys
  def pull_request_review_comments(repo, number, per_page: nil)
    handle_errors do
      comments = if per_page
        client.pull_request_comments(repo, number, per_page: per_page)
      else
        with_auto_paginate do
          client.pull_request_comments(repo, number, per_page: 100)
        end
      end
      comments.map do |c|
        {
          id: c.id,
          user_login: c.user&.login,
          body: c.body.to_s,
          created_at: parse_timestamp(c.created_at)
        }
      end
    end
  end

  # Fetches reactions on a specific pull request review comment.
  #
  # @param repo [String] Repository in "owner/name" format
  # @param comment_id [Integer] The review comment ID
  # @return [Array<Hash>] Reactions with :user_login, :content keys
  def pull_request_review_comment_reactions(repo, comment_id)
    handle_errors do
      reactions = with_auto_paginate do
        client.pull_request_review_comment_reactions(
          repo, comment_id,
          accept: "application/vnd.github.squirrel-girl-preview+json"
        )
      end
      reactions.map do |r|
        {
          user_login: r.user&.login,
          content: r.content,
          created_at: parse_timestamp(r.created_at)
        }
      end
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

  def with_auto_paginate
    original = client.auto_paginate
    client.auto_paginate = true
    yield
  ensure
    client.auto_paginate = original
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

  def pull_request_node_id(repo, number)
    owner, name = repo.split("/", 2)
    query = <<~GRAPHQL
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          pullRequest(number: $number) { id }
        }
      }
    GRAPHQL

    data = graphql_request(query, owner: owner, name: name, number: number)

    if data["errors"].present?
      message = data["errors"].map { |e| e["message"] }.join(", ")
      raise ApiError.new("GraphQL error resolving #{repo}##{number}: #{message}")
    end

    data.dig("data", "repository", "pullRequest", "id")
  end

  def pull_request_node_id!(repo, number)
    node_id = pull_request_node_id(repo, number)
    raise NotFoundError, "Could not find PR node ID for #{repo}##{number}" unless node_id

    node_id
  end

  def parse_timestamp(value)
    case value
    when Time then value
    when String then Time.parse(value)
    end
  end

  # Extracts the token expiration from the GitHub API response header.
  # Fine-grained PATs include a `github-authentication-token-expiration` header
  # with a UTC timestamp. Classic PATs do not include this header.
  #
  # @return [Time, nil] Token expiration time, or nil if not available
  def token_expiration_from_response
    header = client.last_response&.headers&.[]("github-authentication-token-expiration")
    return unless header.present?

    parse_timestamp(header)
  rescue ArgumentError
    nil
  end

  def parse_check_run_timestamp(value)
    return nil if value.nil?
    return value if value.is_a?(Time)

    Time.zone.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
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
