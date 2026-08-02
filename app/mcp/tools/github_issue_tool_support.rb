# frozen_string_literal: true

module Tools
  module GithubIssueToolSupport
    private

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end

    def require_github_client!(project)
      client = project.github_token&.client
      raise ArgumentError, "Project has no GitHub token configured" unless client

      client
    end

    def validate_labels!(client, repo, requested_labels)
      available = label_cache(repo, client)
      unknown = requested_labels - available
      return if unknown.empty?

      raise ArgumentError, "Unknown labels: #{unknown.join(', ')}. Available: #{available.sort.join(', ')}"
    end

    # Cached per-session + repo so repeated issue mutations in one chat
    # reuse the label list.  Rails.cache key includes session.id; the
    # TTL guards against stale labels across long-lived sessions.
    def label_cache(repo, client)
      Rails.cache.fetch("tools/github_issue/label_cache/#{session.id}/#{repo}", expires_in: 5.minutes) do
        client.labels(repo).map { |l| l.is_a?(String) ? l : l.name }
      end
    end
  end
end
