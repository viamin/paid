# frozen_string_literal: true

module Github
  # Warms the GitHub data cache for a project by pre-fetching commonly
  # accessed data. Intended to be called during project sync so that
  # subsequent operations hit the cache instead of the API.
  #
  # Errors from individual fetch operations are caught and logged rather
  # than raised, so a single API failure doesn't prevent other data from
  # being cached.
  #
  # @example
  #   Github::CacheWarmer.call(project: project)
  class CacheWarmer
    attr_reader :project

    def initialize(project:)
      @project = project
    end

    def self.call(...)
      new(...).call
    end

    def call
      return unless project.github_token&.active?

      repo = project.full_name
      warmed = []

      warmed << warm(:repository, repo) { cache_service.repository(repo) }
      warmed << warm(:labels, repo) { cache_service.labels(repo) }
      warmed << warm(:open_issues, repo) { cache_service.issues(repo, state: "open") }
      warmed << warm(:open_pull_requests, repo) { cache_service.pull_requests(repo, state: "open") }

      log_summary(repo, warmed)
    end

    private

    def cache_service
      @cache_service ||= Github::CacheService.new(client: project.github_token.client)
    end

    def warm(resource, repo)
      yield
      resource
    rescue GithubClient::Error => e
      Rails.logger.warn(
        message: "github_cache.warm_failed",
        component: "github_cache",
        repo: repo,
        resource: resource,
        error: e.message
      )
      nil
    end

    def log_summary(repo, warmed)
      succeeded = warmed.compact
      Rails.logger.info(
        message: "github_cache.warmed",
        component: "github_cache",
        repo: repo,
        warmed_count: succeeded.size,
        resources: succeeded
      )
    end
  end
end
