# frozen_string_literal: true

module PullRequests
  # Resolves whether every dependency declared on a pull request's issue is
  # satisfied. Shared by the PR scan (Activities::ScanPaidPrsActivity) and
  # the awaiting_approval escalation re-validation
  # (PullRequests::BlockedOnlyOnApproval) so both sides apply the same
  # dependency gate — extracting a duplicate copy would let the two drift
  # on the next dependency-parsing change.
  #
  # Returns false on any transient API failure that prevents verification,
  # and conservatively when a cross-repo dependency cannot be checked
  # locally.
  class DependenciesResolved
    def self.call(collector:, project:, issue:, logger: Rails.logger)
      new(collector:, project:, issue:, logger:).call
    end

    def initialize(collector:, project:, issue:, logger:)
      @collector = collector
      @project = project
      @issue = issue
      @logger = logger
    end

    def call
      local_deps, cross_deps = Issues::ParseDependencies.extract(
        body: @issue.body,
        comments: @collector.dependency_comment_bodies(issue: @issue)
      )

      return true if local_deps.empty? && cross_deps.empty?

      same_repo = [ @project.owner.downcase, @project.repo.downcase ]
      numbers = cross_deps.each_with_object(Set.new) do |((owner, repo, number), _), set|
        return false unless [ owner, repo ] == same_repo

        set << number
      end

      (local_deps.keys.to_set | numbers).all? { |number| @collector.dependency_resolved?(number:) }
    rescue GithubClient::Error => e
      @logger.warn(
        message: "pr_review.dependency_check_failed",
        project_id: @project.id,
        pr_number: @issue.github_number,
        error: e.message
      )
      false
    end
  end
end
