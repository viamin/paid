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

    # @param client [GithubClient] The underlying GitHub API client
    def initialize(client:)
      @client = client
    end

    # Fetches repository metadata with caching.
    def repository(repo)
      cached(:repository, repo, expires_in: REPO_TTL) do
        client.repository(repo)
      end
    end

    # Fetches a single issue with caching.
    def issue(repo, number)
      cached(:issue, repo, number, expires_in: ISSUE_TTL) do
        client.issue(repo, number)
      end
    end

    # Fetches a pull request with caching.
    def pull_request(repo, number)
      cached(:pull_request, repo, number, expires_in: PULL_REQUEST_TTL) do
        client.pull_request(repo, number)
      end
    end

    # Lists issues for a repository with caching.
    def issues(repo, labels: nil, state: "open", **options)
      key_parts = [ :issues, repo, state, Array(labels).sort.join(",") ]
      cached(*key_parts, expires_in: ISSUES_LIST_TTL) do
        client.issues(repo, labels: labels, state: state, **options)
      end
    end

    # Lists pull requests for a repository with caching.
    def pull_requests(repo, **options)
      key_parts = [ :pull_requests, repo, options.sort.map { |k, v| "#{k}=#{v}" }.join("&") ]
      cached(*key_parts, expires_in: PULL_REQUESTS_LIST_TTL) do
        client.pull_requests(repo, **options)
      end
    end

    # Lists labels for a repository with caching.
    def labels(repo)
      cached(:labels, repo, expires_in: LABELS_TTL) do
        client.labels(repo)
      end
    end

    # Invalidates all cached data for a repository.
    def invalidate_repo(repo)
      instrument(:invalidate, repo: repo, scope: :repo) do
        normalized = Regexp.escape(normalize_repo(repo))
        delete_matched(/#{Regexp.escape(CACHE_NAMESPACE)}\/.*\/#{normalized}/)
      end
    end

    # Invalidates a cached issue and related list caches.
    def invalidate_issue(repo, number)
      instrument(:invalidate, repo: repo, scope: :issue, number: number) do
        Rails.cache.delete(cache_key(:issue, repo, number))
        normalized = Regexp.escape(normalize_repo(repo))
        delete_matched(/#{Regexp.escape(CACHE_NAMESPACE)}\/issues\/#{normalized}/)
      end
    end

    # Invalidates a cached pull request and related list caches.
    def invalidate_pull_request(repo, number)
      instrument(:invalidate, repo: repo, scope: :pull_request, number: number) do
        Rails.cache.delete(cache_key(:pull_request, repo, number))
        normalized = Regexp.escape(normalize_repo(repo))
        delete_matched(/#{Regexp.escape(CACHE_NAMESPACE)}\/pull_requests\/#{normalized}/)
      end
    end

    # Delegates uncached methods directly to the underlying client.
    def method_missing(method, ...)
      if client.respond_to?(method)
        client.public_send(method, ...)
      else
        super
      end
    end

    def respond_to_missing?(method, include_private = false)
      client.respond_to?(method, include_private) || super
    end

    private

    def cached(*key_parts, expires_in:)
      key = cache_key(*key_parts)
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

    def cache_key(*parts)
      normalized = parts.map do |p|
        p.is_a?(String) && p.include?("/") ? normalize_repo(p) : p
      end
      "#{CACHE_NAMESPACE}/#{normalized.join("/")}"
    end

    def normalize_repo(repo)
      repo.downcase
    end

    def delete_matched(pattern)
      Rails.cache.delete_matched(pattern)
    rescue NotImplementedError
      Rails.logger.warn(
        message: "github_cache.delete_matched_unsupported",
        pattern: pattern
      )
    end

    def instrument(event, metadata = {})
      payload = { component: "github_cache" }.merge(metadata)
      ActiveSupport::Notifications.instrument("github_cache.#{event}", payload) do
        block_given? ? yield : nil
      end
    end
  end
end
