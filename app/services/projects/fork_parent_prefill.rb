# frozen_string_literal: true

module Projects
  # Fetches fork-parent metadata for a GitHub repository so the settings UI
  # can prefill upstream_full_name for open-source / upstream PR target
  # projects (issue #4076). GitHub exposes this as `parent.full_name` on the
  # repository payload; the field is only present for literal GitHub forks.
  #
  # Expected GitHub errors (network, auth, rate limit, not found) are
  # caught and logged so settings pages can still render with manual entry.
  # Anything else propagates to the caller — the controller's logging
  # boundary needs to see it so operators can distinguish a real bug from
  # an expected GitHub outage or credential failure.
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
      client = github_client || project.client
      return Prefill.unavailable("no_github_credential") if client.nil?

      payload = client.repository(project.full_name)
      parent_full_name = read_parent_full_name(payload)
      return Prefill.unavailable("not_a_fork") if parent_full_name.blank?
      return Prefill.unavailable("same_as_project") if parent_full_name.casecmp?(project.full_name)

      Prefill.detected(parent_full_name)
    rescue GithubClient::Error, Octokit::Error => e
      Rails.logger.info(
        message: "projects.fork_parent_prefill.skipped",
        component: "project_settings",
        project_id: project.id,
        reason: e.class.name
      )
      Prefill.unavailable("github_request_failed")
    end

    private

    attr_reader :project, :github_client

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
    # hint, the manual-only form, or an error banner.
    Prefill = Struct.new(:status, :upstream_full_name, :reason, keyword_init: true) do
      def self.detected(upstream_full_name)
        new(status: :detected, upstream_full_name: upstream_full_name, reason: PREFILLABLE_REASON)
      end

      def self.unavailable(reason)
        new(status: :unavailable, upstream_full_name: nil, reason: reason)
      end

      def detected?
        status == :detected
      end
    end
  end
end
