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
      queue_as :default

      def perform(installation_id:, account_id:, setup_action: nil)
        return if installation_id.blank? || account_id.blank?

        account = Account.find_by(id: account_id)
        return unless account

        payload = fetch_installation(installation_id)
        return unless payload

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

        return nil unless response.success?

        JSON.parse(response.body)
      rescue Faraday::Error => e
        raise Github::AppInstallation::Error, "Failed to fetch installation #{installation_id}: #{e.message}"
      rescue JSON::ParserError
        raise Github::AppInstallation::Error, "GitHub returned invalid JSON for installation #{installation_id}"
      end
    end
  end
end
