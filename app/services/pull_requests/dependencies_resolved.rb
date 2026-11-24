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
  # and conservatively when a cross-repo dependency is not tracked by the
  # same account.
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

    def call # @spec DEPENDENCY-DECLARATIONS-005, DEPENDENCY-DECLARATIONS-010, AUTO-MERGE-010
      local_deps, cross_deps = Issues::ParseDependencies.extract(
        body: @issue.body,
        comments: @collector.dependency_comment_bodies(issue: @issue),
        current_issue_number: @issue.github_number
      )

      return true if local_deps.empty? && cross_deps.empty?

      return false unless cross_deps.all? { |(owner, repo, number), _| cross_dependency_resolved?(owner:, repo:, number:) }

      local_deps.keys.all? { |number| @collector.dependency_resolved?(number:) }
    rescue GithubClient::Error => e
      @logger.warn(
        message: "pr_review.dependency_check_failed",
        project_id: @project.id,
        pr_number: @issue.github_number,
        error: e.message
      )
      false
    end

    private

    def cross_dependency_resolved?(owner:, repo:, number:)
      return @collector.dependency_resolved?(number:) if current_repository?(owner:, repo:)

      target_project = tracked_project(owner:, repo:)
      return false unless target_project

      external_collector = collector_for(target_project)
      return false unless external_collector

      external_collector.dependency_resolved?(number:)
    end

    def tracked_project(owner:, repo:)
      return unless @project.respond_to?(:account) && @project.account

      @project.account.projects.find_by(
        "LOWER(owner) = ? AND LOWER(repo) = ?", owner.downcase, repo.downcase
      )
    end

    def current_repository?(owner:, repo:)
      [ owner.downcase, repo.downcase ] == [ @project.owner.downcase, @project.repo.downcase ]
    end

    def collector_for(target_project)
      return @collector if target_project.id == @project.id

      client = target_project.client
      return unless client

      Automation::Signals::PullRequestCollector.new(
        providers: Automation::Signals::ProviderContext.for(target_project, client:),
        client:,
        logger: @logger
      )
    end
  end
end
