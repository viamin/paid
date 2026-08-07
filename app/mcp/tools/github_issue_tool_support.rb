# frozen_string_literal: true

module Tools
  module GithubIssueToolSupport
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      # Short-circuit for account-level roles (owner, admin, member) before
      # scanning the policy scope, avoiding a full project scan on every chat
      # tool advertisement call. Mirrors BaseTool.run_agent_available_to?.
      def available_to?(user:)
        return false if user.blank?

        record = Project.new(account: user.account)
        return true if policy_allows?(user:, record:, query: :manage_issues?, policy_class: ProjectPolicy)

        Pundit.policy_scope!(user, Project).any? do |project|
          policy_allows?(user:, record: project, query: :manage_issues?, policy_class: ProjectPolicy)
        end
      rescue Pundit::NotAuthorizedError
        false
      end

      # GitHub issue mutations (create/edit/label) are reversible and scoped to
      # a single repo, so they are safe for the per-session auto-approve toggle
      # (issue #3270). Pundit still authorizes manage_issues? at dispatch time.
      def auto_approve_eligible?
        true
      end
    end

    private

    def project_for(project_id)
      @projects_by_id ||= {}
      @projects_by_id[project_id] ||= policy_scope(Project).find(project_id)
    end

    def require_github_client!(project)
      client = project.client
      raise ArgumentError, "Project has no GitHub credential configured" unless client

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
