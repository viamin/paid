# frozen_string_literal: true

module Github
  # Caching layer for frequently accessed GitHub API data.
  #
  # Wraps GithubClient read methods with Rails.cache TTL-based expiration.
  # Write operations bypass the cache and invalidate related entries.
  #
  # Cache keys are scoped by repo to allow targeted invalidation when
  # webhooks fire for a specific repository.
  #
  # @example
  #   cache = Github::CacheService.new(client: github_client)
  #   repo = cache.repository("owner/repo")       # fetches and caches
  #   repo = cache.repository("owner/repo")       # cache hit
  #   cache.invalidate_repo("owner/repo")          # clears all cached data for repo
  class CacheService
    REPO_TTL = 1.hour
    ISSUE_TTL = 15.minutes
    PULL_REQUEST_TTL = 10.minutes
    ISSUES_LIST_TTL = 5.minutes
    PULL_REQUESTS_LIST_TTL = 5.minutes
    LABELS_TTL = 30.minutes

    CACHE_NAMESPACE = "github"

    attr_reader :client

    # @param client [GithubClient, nil] The underlying GitHub API client.
    #   Required for fetch operations; may be omitted for invalidation-only use.
    def initialize(client: nil)
      @client = client
    end

    # Fetches repository metadata with caching.
    def repository(repo)
      cached(:repository, repo: repo, expires_in: REPO_TTL) do
        client.repository(repo)
      end
    end

    # Fetches a single issue with caching.
    def issue(repo, number)
      cached(:issue, number, repo: repo, expires_in: ISSUE_TTL) do
        client.issue(repo, number)
      end
    end

    # Fetches a pull request with caching.
    def pull_request(repo, number)
      cached(:pull_request, number, repo: repo, expires_in: PULL_REQUEST_TTL) do
        client.pull_request(repo, number)
      end
    end

    # Lists issues for a repository with caching.
    def issues(repo, labels: nil, state: "open", **options)
      extra = options.sort.map { |k, v| "#{k}=#{v}" }.join("&")
      cached(:issues, state, Array(labels).sort.join(","), extra, repo: repo, expires_in: ISSUES_LIST_TTL) do
        client.issues(repo, labels: labels, state: state, **options)
      end
    end

    # Lists pull requests for a repository with caching.
    def pull_requests(repo, **options)
      extra = options.sort.map { |k, v| "#{k}=#{v}" }.join("&")
      cached(:pull_requests, extra, repo: repo, expires_in: PULL_REQUESTS_LIST_TTL) do
        client.pull_requests(repo, **options)
      end
    end

    # Lists labels for a repository with caching.
    def labels(repo)
      cached(:labels, repo: repo, expires_in: LABELS_TTL) do
        client.labels(repo)
      end
    end

    # Invalidates all cached data for a repository by bumping the
    # per-repo version counter. Existing entries expire naturally via TTL;
    # no Redis SCAN is required.
    def invalidate_repo(repo)
      instrument(:invalidate, repo: repo, scope: :repo) do
        bump_repo_version(repo)
      end
    end

    # Invalidates a cached issue and related list caches by bumping
    # the repo version so all keys (including list caches with varying
    # query parameters) become unreachable.
    def invalidate_issue(repo, number)
      instrument(:invalidate, repo: repo, scope: :issue, number: number) do
        bump_repo_version(repo)
      end
    end

    # Invalidates a cached pull request and related list caches by
    # bumping the repo version.
    def invalidate_pull_request(repo, number)
      instrument(:invalidate, repo: repo, scope: :pull_request, number: number) do
        bump_repo_version(repo)
      end
    end

    # Delegates uncached methods directly to the underlying client.
    def method_missing(method, ...)
      if client&.respond_to?(method)
        client.public_send(method, ...)
      else
        super
      end
    end

    def respond_to_missing?(method, include_private = false)
      client&.respond_to?(method, include_private) || super
    end

    private

    def cached(*key_parts, repo:, expires_in:)
      key = cache_key(*key_parts, repo: repo)
      hit = true

      result = Rails.cache.fetch(key, expires_in: expires_in) do
        hit = false
        yield
      end

      if hit
        instrument(:hit, cache_key: key)
      else
        instrument(:miss, cache_key: key)
      end

      result
    end

    def cache_key(*parts, repo:)
      version = repo_version(repo)
      "#{CACHE_NAMESPACE}/v#{version}/#{normalize_repo(repo)}/#{parts.join("/")}"
    end

    def normalize_repo(repo)
      repo.downcase
    end

    def repo_version_key(repo)
      "#{CACHE_NAMESPACE}:repo_version:#{normalize_repo(repo)}"
    end

    def repo_version(repo)
      Rails.cache.read(repo_version_key(repo)) || 0
    end

    def bump_repo_version(repo)
      key = repo_version_key(repo)
      Rails.cache.increment(key, 1, expires_in: 1.day)
    end

    def instrument(event, metadata = {})
      payload = { component: "github_cache" }.merge(metadata)
      ActiveSupport::Notifications.instrument("github_cache.#{event}", payload) do
        block_given? ? yield : nil
      end
    end
  end
end
