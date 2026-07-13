# frozen_string_literal: true

module Api
module GithubApp
  # Receives GitHub App installation lifecycle webhooks and reconciles the
  # local GithubInstallation table.
  #
  # Supported event types:
  #   - installation                              (created/updated/suspend/unsuspend/deleted)
  #   - installation_repositories                 (added/removed)
  #
  # Webhook authenticity is verified using the shared App webhook secret
  # resolved via `Github::AppRegistry.webhook_secret` (which checks
  # `PAID_AGENT_APP_WEBHOOK_SECRET` first and falls back to the
  # `paid_agent_app_webhook_secret` Rails credential). In multi-tenant SaaS
  # this secret is rotated with the App itself; in self-hosted deployments it
  # is supplied via Rails credentials at app setup time.
  class WebhooksController < ActionController::API
    before_action :verify_signature

    # POST /webhooks/github_app
    def create
      event = request.headers["X-GitHub-Event"].to_s
      action = payload["action"].to_s
      handler = handler_for(event, action)

      if handler.nil?
        Rails.logger.info(
          message: "github_app.webhook.ignored",
          event: event,
          action: action
        )
        head :ok
        return
      end

      perform_handler(handler)
      head :ok
    rescue StandardError => e
      Rails.logger.warn(
        message: "github_app.webhook.failed",
        event: event,
        action: action,
        error: e.message
      )
      head :unprocessable_entity
    end

    def perform_handler(handler)
      case handler
      when :upsert_installation
        upsert_installation
      when :repositories_added, :repositories_removed
        reconcile_repositories
      end
    end

    def handler_for(event, action)
      case event
      when "installation"
        :upsert_installation
      when "installation_repositories"
        case action
        when "added" then :repositories_added
        when "removed" then :repositories_removed
        end
      end
    end

    # `installation` events (created/updated/suspend/unsuspend/deleted) are the
    # only lifecycle events that carry full installation metadata, so they must
    # create or recover the local row rather than requiring it to already exist.
    # The owning account is inferred via AccountResolver; if it cannot be mapped
    # to a single tenant we log and drop instead of guessing.
    def upsert_installation
      account = Github::Installations::AccountResolver.call(payload: payload)
      unless account
        Rails.logger.info(
          message: "github_app.webhook.unresolved_installation",
          installation_id: payload.dig("installation", "id"),
          action: payload["action"]
        )
        return
      end

      TenantContext.with(account) do
        Github::Installations::Upserter.call(account: account, payload: payload)
      end
    end

    # installation_repositories events only carry repository deltas, not enough
    # metadata to create an installation, so they still require the local row.
    # A missing row is recovered by the next `installation` event.
    def reconcile_repositories
      installation_id = payload.dig("installation", "id")
      record = lookup_installation(installation_id)
      return unless record

      TenantContext.with(record.account) do
        Github::Installations::RepositoriesReconciler.call(installation: record, payload: payload)
      end
    end

    def lookup_installation(installation_id)
      return nil if installation_id.blank?

      TenantContext.with_system_access do
        GithubInstallation.find_by(github_installation_id: installation_id)
      end
    end

    def payload
      @payload ||= JSON.parse(request.body.read)
    rescue JSON::ParserError
      {}
    end

    def verify_signature
      signature = request.headers["X-Hub-Signature-256"].to_s
      secret = Github::AppRegistry.webhook_secret

      if secret.blank? || signature.blank?
        head :unauthorized
        return
      end

      request.body.rewind
      body = request.body.read
      request.body.rewind

      expected = "sha256=#{OpenSSL::HMAC.hexdigest("SHA256", secret, body)}"
      if signature.bytesize != expected.bytesize ||
          !ActiveSupport::SecurityUtils.secure_compare(expected, signature)
        head :unauthorized
      end
    end
  end
end
end
