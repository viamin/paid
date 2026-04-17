# frozen_string_literal: true

module Github
  # Invalidates cached GitHub data in response to webhook events.
  #
  # Called from the webhook controller when GitHub notifies us of changes
  # to issues, pull requests, or repository metadata. Uses the same cache
  # key structure as {Github::CacheService} to target specific entries.
  #
  # @example From a webhook handler
  #   Github::CacheInvalidator.call(
  #     project: project,
  #     event: "pull_request",
  #     payload: webhook_payload
  #   )
  class CacheInvalidator
    attr_reader :project, :event, :payload

    def initialize(project:, event:, payload:)
      @project = project
      @event = event
      @payload = payload
    end

    def self.call(...)
      new(...).call
    end

    def call
      return unless project

      case event
      when "pull_request"
        invalidate_pull_request
      when "pull_request_review"
        invalidate_pull_request_review
      when "issues"
        invalidate_issue
      when "issue_comment"
        invalidate_issue_comment
      when "push"
        invalidate_repo_metadata
      end
    end

    private

    def repo_full_name
      @repo_full_name ||= project.full_name
    end

    def cache_service
      @cache_service ||= Github::CacheService.new(client: nil_client)
    end

    def invalidate_pull_request
      number = payload.dig("pull_request", "number")
      return unless number

      cache_service.invalidate_pull_request(repo_full_name, number)
    end

    def invalidate_pull_request_review
      number = payload.dig("pull_request", "number")
      return unless number

      cache_service.invalidate_pull_request(repo_full_name, number)
    end

    def invalidate_issue
      number = payload.dig("issue", "number")
      return unless number

      cache_service.invalidate_issue(repo_full_name, number)
    end

    def invalidate_issue_comment
      issue = payload["issue"] || {}
      number = issue["number"]
      return unless number

      if issue["pull_request"]
        cache_service.invalidate_pull_request(repo_full_name, number)
      else
        cache_service.invalidate_issue(repo_full_name, number)
      end
    end

    def invalidate_repo_metadata
      cache_service.invalidate_repo(repo_full_name)
    end

    # Stub client for invalidation-only operations. The cache service
    # only needs the client for fetching; invalidation uses Rails.cache
    # directly via the cache key helpers.
    def nil_client
      @nil_client ||= NilClient.new
    end

    # Minimal stand-in that satisfies CacheService#initialize without
    # requiring a real GithubClient (and therefore a token).
    class NilClient
      def respond_to_missing?(*, **)
        false
      end
    end
  end
end
