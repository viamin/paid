# frozen_string_literal: true

module Github
  module Installations
    # Persists or updates a GithubInstallation record from a GitHub App
    # installation event payload.
    #
    # GitHub fires the following events that touch installations:
    #   - installation.created      → create the record
    #   - installation.updated      → refresh account_login / repository_selection
    #   - installation.new_permissions_accepted → refresh after a customer accepts
    #                                            new permissions on an existing install
    #   - installation.suspend      → set suspended_at
    #   - installation.unsuspend    → clear suspended_at
    #   - installation.deleted      → set revoked_at (we keep the row so audit /
    #                                            project references remain intact)
    #   - installation_repositories.added   → merge repositories into accessible_repositories
    #   - installation_repositories.removed → remove repositories from accessible_repositories
    #
    # All upserts are scoped to a single account. The caller is responsible for
    # resolving the account_id (e.g. from the incoming webhook state, the
    # authenticated user, or a system context for self-hosted installations).
    class Upserter
      class Error < StandardError; end

      attr_reader :account, :payload

      def self.call(account:, payload:)
        new(account: account, payload: payload).call
      end

      def initialize(account:, payload:)
        @account = account
        @payload = payload || {}
      end

      def call
        installation = payload["installation"] || {}
        installation_id = installation["id"]
        if installation_id.blank?
          raise Error, "installation event missing installation.id"
        end

        record = find_or_initialize(installation_id)
        apply_attributes(record, installation)
        record.save!
        record
      end

      private

      def find_or_initialize(installation_id)
        TenantContext.with_system_access do
          scope = GithubInstallation.where(github_installation_id: installation_id)
          scope.first || GithubInstallation.new(
            account_id: account.id,
            github_installation_id: installation_id
          )
        end
      end

      def apply_attributes(record, installation)
        record.account_id = account.id if record.account_id.blank?

        record.account_login = installation["account"].dig("login") if installation["account"].present?
        record.target_type = installation.dig("target_type") if installation["target_type"].present?
        # `repository_selection` lives on `installation` in both webhook and
        # REST shapes — `installation` event webhooks put it under installation,
        # not at the top level alongside `repositories` and `requester`.
        record.repository_selection = installation["repository_selection"] if installation["repository_selection"].present?

        # GitHub's `installation.created` / `installation.new_permissions_accepted`
        # webhooks put the granted repositories at the TOP level of the payload
        # (alongside `installation`, `requester`, `sender`), NOT under
        # `installation`. Reading `installation["repositories"]` would return
        # nil for real webhook payloads and leave `accessible_repositories`
        # empty until the next `installation_repositories.added` event. The
        # REST `/app/installations/:id` response has no `repositories` field
        # at all — only webhooks do — so falling back to that is safe.
        repositories = payload["repositories"] || installation["repositories"]
        if repositories.is_a?(Array)
          record.accessible_repositories = serialize_repositories(repositories)
          record.repositories_synced_at = Time.current
        end

        action = payload["action"].to_s
        case action
        when "deleted"
          record.revoked_at ||= Time.current
          record.suspended_at = nil
        when "suspend"
          record.suspended_at ||= Time.current
        when "unsuspend"
          record.suspended_at = nil
        when "created", "new_permissions_accepted"
          record.suspended_at = nil
          record.revoked_at = nil
        end

        # installation.updated may follow suspend/unsuspend on the same payload;
        # the action handler above is the source of truth for suspended/revoked.
        record
      end

      def serialize_repositories(repositories)
        repositories.map do |repo|
          next unless repo.is_a?(Hash)

          full_name = repo["full_name"]
          name = repo["name"] || full_name.to_s.split("/").last
          owner = repo["owner"].is_a?(Hash) ? repo.dig("owner", "login") : repo["owner"]
          owner ||= full_name.to_s.split("/").first

          {
            "id" => repo["id"],
            "full_name" => full_name,
            "name" => name,
            "owner" => owner,
            "default_branch" => repo["default_branch"],
            "private" => repo["private"] || false
          }.compact
        end.compact
      end
    end
  end
end
