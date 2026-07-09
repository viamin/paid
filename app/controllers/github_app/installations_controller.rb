# frozen_string_literal: true

module GithubApp
  # Handles the user-facing GitHub App install/callback lifecycle.
  #
  # The flow:
  #   1. The user clicks "Install paid-agents" in the integrations UI.
  #   2. The browser requests `GET /github_app/install`, which mints a
  #      CSRF state token, stores it in the session, and 302s to
  #      `https://github.com/apps/<slug>/installations/new?state=...`.
  #   3. After the user installs the App on GitHub, GitHub redirects back to
  #      `GET /github_app/callback?installation_id=...&setup_action=...&state=...`.
  #      The controller verifies the state, then enqueues
  #      `Github::Installations::SyncJob` to fetch full installation
  #      metadata and persist the `GithubInstallation` record.
  #
  # Webhook-driven lifecycle updates (suspend, repositories added/removed,
  # uninstall) are handled by `GithubApp::WebhooksController`, not here.
  class InstallationsController < ApplicationController
    include AuditLogging

    INSTALL_STATE_SESSION_KEY = :github_app_install_state
    INSTALL_STATE_TTL = 15.minutes

    skip_after_action :verify_authorized, :verify_policy_scoped

    before_action :require_app_configured!, only: [ :install ]
    before_action :verify_install_state!, only: :callback

    # GET /github_app/install
    # Generates CSRF state, stores in session, redirects to GitHub install URL.
    def install
      state = SecureRandom.urlsafe_base64(32)
      session[INSTALL_STATE_SESSION_KEY] = {
        token: state,
        account_id: current_account.id,
        issued_at: Time.current.to_i
      }

      redirect_to Github::AppRegistry.install_url(state: state), allow_other_host: true
    end

    # GET /github_app/callback
    # Handles the post-install redirect from GitHub. Persists the
    # GithubInstallation record asynchronously and redirects the user to
    # the project picker for the newly installed organization/account.
    def callback
      installation_id = params[:installation_id].to_i
      setup_action = params[:setup_action].presence

      clear_install_state!

      if installation_id.zero?
        redirect_to integrations_path, alert: "Missing installation_id from GitHub callback."
        return
      end

      Github::Installations::SyncJob.perform_later(
        installation_id: installation_id,
        account_id: session_account_id || current_account.id,
        setup_action: setup_action
      )

      redirect_to integrations_path,
        notice: "GitHub App installation received. Repository details will appear shortly."
    end

    private

    def require_app_configured!
      return if Github::AppRegistry.configured?

      redirect_to integrations_path,
        alert: "The paid-agents GitHub App is not configured for this deployment."
    end

    def verify_install_state!
      stored = session[INSTALL_STATE_SESSION_KEY]
      expected = params[:state].to_s

      if stored.blank? || expected.blank? || !ActiveSupport::SecurityUtils.secure_compare(stored[:token].to_s, expected)
        redirect_to integrations_path, alert: "GitHub App installation state did not match."
      elsif stored[:issued_at].to_i < (Time.current - INSTALL_STATE_TTL).to_i
        clear_install_state!
        redirect_to integrations_path, alert: "GitHub App installation request expired. Please try again."
      end
    end

    def clear_install_state!
      session.delete(INSTALL_STATE_SESSION_KEY)
    end

    def session_account_id
      session[INSTALL_STATE_SESSION_KEY]&.dig(:account_id)
    end
  end
end