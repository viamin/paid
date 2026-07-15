# frozen_string_literal: true

module Github
  module Installations
    # Resolves the Paid Account that owns an incoming GitHub App `installation`
    # webhook, so the installation can be persisted even when the browser
    # install callback never completed (or the local row was deleted).
    #
    # Webhooks carry no Paid account identifier, so resolution is inferred from
    # data the App already knows about, in order of confidence:
    #
    #   1. An existing GithubInstallation row for this installation id — the
    #      authoritative binding created by the install callback or a prior
    #      webhook.
    #   2. An active PendingInstallClaim for this installation id — the
    #      server-trusted signal written by the install callback when the
    #      state CSRF was verified (SaaS flow) or when the operator was
    #      signed in for the self-hosted `setup_url` flow. This is the
    #      binding path for a first install into a brand-new org where
    #      neither an existing row nor a matching project exists yet.
    #   3. The installation's granted repositories matched against connected
    #      Projects (owner/repo). Recovers a deleted row for an org that is
    #      already using Paid.
    #   4. The installer's account login matched against a prior installation
    #      for the same login.
    #
    # Every strategy only returns an account when it maps to exactly one Paid
    # account. Ambiguous matches resolve to nil so we never bind an installation
    # (and its repository access) to the wrong tenant. When nothing resolves the
    # caller logs and drops the event.
    class AccountResolver
      def self.call(payload:)
        new(payload: payload).call
      end

      def initialize(payload:)
        @payload = payload || {}
        @installation = @payload["installation"] || {}
      end

      def call
        by_installation_id || by_pending_claim || by_repositories || by_account_login
      end

      private

      attr_reader :installation

      def by_installation_id
        installation_id = installation["id"]
        return nil if installation_id.blank?

        TenantContext.with_system_access do
          GithubInstallation.find_by(github_installation_id: installation_id)&.account
        end
      end

      def by_pending_claim
        installation_id = installation["id"]
        return nil if installation_id.blank?

        account_ids = TenantContext.with_system_access do
          PendingInstallClaim.active.where(github_installation_id: installation_id)
            .distinct.pluck(:account_id)
        end

        single_account(account_ids)
      end

      def by_repositories
        pairs = repository_pairs.uniq
        return nil if pairs.empty?

        scope = pairs.reduce(Project.none) do |combined, (owner, repo)|
          combined.or(Project.where(owner: owner, repo: repo))
        end

        account_ids = TenantContext.with_system_access { scope.distinct.pluck(:account_id) }

        single_account(account_ids)
      end

      def by_account_login
        login = installation.dig("account", "login")
        return nil if login.blank?

        account_ids = TenantContext.with_system_access do
          GithubInstallation.where(account_login: login).distinct.pluck(:account_id)
        end

        single_account(account_ids)
      end

      def repository_pairs
        # GitHub's `installation.created` / `installation.new_permissions_accepted`
        # webhooks expose repository matches at the TOP level of the payload
        # (alongside `installation`, `requester`, `sender`), not under
        # `installation`. Without this fallback `by_repositories` always
        # returned an empty list for real webhook payloads, and a deleted
        # installation row for an existing org could not be recovered.
        sources = Array(@payload["repositories"]).presence || Array(installation["repositories"])

        sources.filter_map do |repo|
          next unless repo.is_a?(Hash)

          owner, name = repo["full_name"].to_s.split("/", 2)
          [ owner, name ] if owner.present? && name.present?
        end
      end

      def single_account(account_ids)
        return nil unless account_ids.one?

        Account.find_by(id: account_ids.first)
      end
    end
  end
end
