# frozen_string_literal: true

module Projects
  # Fetches fork-parent metadata for a GitHub repository so the settings UI
  # can prefill upstream_owner / upstream_repo for open-source / upstream PR
  # target projects (issue #4076). GitHub exposes the parent as
  # `parent.full_name` on the repository payload; the field is only present
  # for literal GitHub forks.
  #
  # The result is deliberately non-raising — settings pages should still
  # render (with manual entry) when GitHub is unreachable, the credential
  # lacks `repo` scope, or the repository simply is not a fork.
  class ForkParentPrefill
    PREFILLABLE_REASON = "detected_from_fork_parent".freeze

    # @return [Prefill] describing whether a fork parent could be detected.
    def self.call(project, github_client: nil)
      new(project, github_client: github_client).call
    end

    def initialize(project, github_client: nil)
      @project = project
      @github_client = github_client
    end

    def call
      client = github_client || @project.client
      return Prefill.unavailable("no_github_credential") if client.nil?

      payload = fetch_repository(client)
      return Prefill.unavailable("github_request_failed") if payload.nil?

      parent_full_name = read_parent_full_name(payload)
      return Prefill.unavailable("not_a_fork") if parent_full_name.blank?
      return Prefill.unavailable("same_as_project") if parent_full_name.casecmp?(@project.full_name)

      owner, repo = parent_full_name.split("/", 2)
      Prefill.detected(owner, repo)
    rescue GithubClient::Error, Octokit::Error => e
      Rails.logger.info(
        message: "projects.fork_parent_prefill.skipped",
        component: "project_settings",
        project_id: @project.id,
        reason: e.class.name
      )
      Prefill.unavailable("github_request_failed")
    end

    private

    attr_reader :project

    def github_client
      @github_client
    end

    def fetch_repository(client)
      client.repository(project.full_name)
    rescue StandardError
      nil
    end

    def read_parent_full_name(payload)
      parent = if payload.respond_to?(:[])
        payload[:parent] || payload["parent"]
      end
      return if parent.nil?

      if parent.respond_to?(:[])
        (parent[:full_name] || parent["full_name"]).presence
      end
    end

    # Result returned to callers — they decide whether to render the prefill
    # hint, the manual-only form, or an error banner. {#upstream_full_name}
    # is derived from the split fields so views that want the legacy single
    # value can keep using it.
    Prefill = Struct.new(:status, :upstream_owner, :upstream_repo, :reason, keyword_init: true) do
      def self.detected(upstream_owner, upstream_repo)
        new(
          status: :detected,
          upstream_owner: upstream_owner,
          upstream_repo: upstream_repo,
          reason: PREFILLABLE_REASON
        )
      end

      def self.unavailable(reason)
        new(status: :unavailable, upstream_owner: nil, upstream_repo: nil, reason: reason)
      end

      def detected?
        status == :detected
      end

      def upstream_full_name
        return nil unless upstream_owner.present? && upstream_repo.present?

        "#{upstream_owner}/#{upstream_repo}"
      end
    end
  end
end
