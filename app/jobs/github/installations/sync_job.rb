# frozen_string_literal: true

module Github
  module Installations
    # Fetches the full installation record from GitHub and upserts the local
    # GithubInstallation row. Triggered from the install callback and may
    # also be replayed manually from the operator console.
    #
    # The job runs under system tenant context because it may be processing
    # webhooks or callbacks for accounts the worker does not belong to.
    class SyncJob < ApplicationJob
      # Raised when GitHub is temporarily unavailable (5xx / 429 / timeout /
      # connection failure). These are retried so a transient blip does not
      # permanently drop a callback sync — the user already saw a success
      # notice, so the row must eventually be created.
      class TransientError < StandardError; end

      queue_as :default

      retry_on TransientError, wait: :polynomially_longer, attempts: 5

      def perform(installation_id:, account_id:, setup_action: nil)
        return if installation_id.blank? || account_id.blank?

        account = Account.find_by(id: account_id)
        return unless account

        payload = fetch_installation(installation_id)
        return unless payload

        unless callback_binding_trusted?(installation_id: installation_id, account: account, payload: payload)
          Rails.logger.warn(
            message: "github_app.installation_callback_binding_refused",
            installation_id: installation_id,
            account_id: account_id,
            account_login: payload.dig("account", "login"),
            setup_action: setup_action,
            reason: "no matching project owner or prior installation row"
          )
          return
        end

        TenantContext.with(account) do
          Github::Installations::Upserter.call(
            account: account,
            payload: wrap_payload(payload, derive_action(setup_action, payload["action"]))
          )
        end

        Rails.logger.info(
          message: "github_app.installation_synced",
          installation_id: installation_id,
          account_id: account_id,
          setup_action: setup_action
        )
      rescue Github::AppInstallation::Error, Github::Installations::Upserter::Error => e
        Rails.logger.warn(
          message: "github_app.installation_sync_failed",
          installation_id: installation_id,
          account_id: account_id,
          error: e.message
        )
      end

      private

      def derive_action(setup_action, payload_action)
        case setup_action
        when "install" then "created"
        when "update" then "updated"
        else payload_action || "created"
        end
      end

      # The Upserter expects a GitHub webhook payload with the installation
      # nested under the "installation" key. The /app/installations/:id REST
      # endpoint returns the installation directly at the top level, so wrap
      # it before handing off.
      def wrap_payload(installation, action)
        { "action" => action, "installation" => installation }
      end

      def fetch_installation(installation_id)
        jwt = Github::AppJwt.sign(
          app_id: Github::AppRegistry.app_id,
          private_key: Github::AppRegistry.private_key
        )
        response = Faraday.get("#{Github::AppInstallation::API_BASE_URL}/app/installations/#{installation_id}") do |request|
          request.headers["Accept"] = "application/vnd.github+json"
          request.headers["Authorization"] = "Bearer #{jwt}"
          request.headers["X-GitHub-Api-Version"] = "2022-11-28"
          request.options.timeout = 30
          request.options.open_timeout = 10
        end

        return JSON.parse(response.body) if response.success?

        raise_for_status(response, installation_id)
      rescue Faraday::TimeoutError, Faraday::ConnectionFailed => e
        # Network-level failures are always transient — retry.
        raise TransientError, "Failed to fetch installation #{installation_id}: #{e.message}"
      rescue Faraday::Error => e
        raise Github::AppInstallation::Error, "Failed to fetch installation #{installation_id}: #{e.message}"
      rescue JSON::ParserError
        raise Github::AppInstallation::Error, "GitHub returned invalid JSON for installation #{installation_id}"
      end

      # A non-2xx response must not be swallowed: 5xx/429 are transient and get
      # retried; every other status (404 gone, 401/403 misconfiguration) is
      # permanent and is logged-and-dropped by the caller's rescue.
      def raise_for_status(response, installation_id)
        if retryable_status?(response.status)
          raise TransientError, "GitHub returned #{response.status} fetching installation #{installation_id}"
        end

        raise Github::AppInstallation::Error,
          "GitHub returned #{response.status} fetching installation #{installation_id}"
      end

      def retryable_status?(status)
        status >= 500 || status == 429
      end

      # GitHub's setup URL params (notably `installation_id`) are spoofable —
      # a signed-in user could complete the local callback with an
      # `installation_id` they do not actually own. The CSRF `state` only
      # proves the user clicked Paid's install button, not that they
      # completed the GitHub side of the flow. We therefore gate the
      # callback-driven sync on at least one server-trusted signal that the
      # `(installation_id, account_id)` pair is legitimate:
      #
      #   1. An active `PendingInstallClaim` written by the callback (only
      #      when the state CSRF was verified or the operator was signed in
      #      for the self-hosted `setup_url` flow). This is the binding
      #      path for a first install into a brand-new org where neither an
      #      existing row nor a matching project exists yet.
      #   2. An existing GithubInstallation row for this installation_id,
      #      owned by the same account — re-installs / permission updates.
      #   3. The installation's `account.login` matches the owner of one of
      #      the account's Projects — the user has a project in that org
      #      already.
      #
      # When none of the signals holds, the sync is deferred to the signed
      # `installation` webhook, which is the trusted binding path. The
      # webhook's `AccountResolver` consults the same `PendingInstallClaim`
      # to finalize the binding.
      def callback_binding_trusted?(installation_id:, account:, payload:)
        active_claim = TenantContext.with_system_access do
          PendingInstallClaim.active.find_by(
            account_id: account.id, github_installation_id: installation_id
          )
        end
        return true if active_claim

        existing_owner = TenantContext.with_system_access do
          GithubInstallation.where(github_installation_id: installation_id, account_id: account.id)
            .exists?
        end
        return true if existing_owner

        installation_login = payload.dig("account", "login").to_s.downcase
        return false if installation_login.blank?

        TenantContext.with_system_access do
          Project.where(account_id: account.id, owner: installation_login).exists?
        end
      end
    end
  end
end
