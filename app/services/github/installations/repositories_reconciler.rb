# frozen_string_literal: true

module Github
  module Installations
    # Reconciles a GithubInstallation's accessible_repositories cache with the
    # GitHub App installation_repositories event payload.
    #
    # event action can be "added" or "removed". The repositories_removed array
    # is only present on "removed" events; on "added" events we use
    # repositories_added.
    class RepositoriesReconciler
      class Error < StandardError; end

      attr_reader :installation, :payload

      def self.call(installation:, payload:)
        new(installation: installation, payload: payload).call
      end

      def initialize(installation:, payload:)
        @installation = installation
        @payload = payload || {}
      end

      def call
        action = payload["action"].to_s
        return installation unless %w[added removed].include?(action)

        existing = Array(installation.accessible_repositories).map(&:with_indifferent_access)
        changed = payload_repositories
        next_list =
          case action
          when "added" then merge_added(existing, changed)
          when "removed" then remove_listed(existing, changed)
          end

        installation.update!(
          accessible_repositories: next_list,
          repositories_synced_at: Time.current
        )
        installation
      end

      private

      def payload_repositories
        Array(payload["repositories_added"] || payload["repositories_removed"]).map do |repo|
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
          }.with_indifferent_access.compact
        end.compact
      end

      def merge_added(existing, added)
        by_id = existing.index_by { |repo| repo["id"] }
        added.each { |repo| by_id[repo["id"]] = repo }
        by_id.values
      end

      def remove_listed(existing, removed)
        removed_ids = removed.map { |repo| repo["id"] }.compact.to_set
        existing.reject { |repo| removed_ids.include?(repo["id"]) }
      end
    end
  end
end