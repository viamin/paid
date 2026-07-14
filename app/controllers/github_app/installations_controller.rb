# frozen_string_literal: true

module GithubApp
  # Handles the user-facing GitHub App install/callback lifecycle.
  #
  # Two ways to reach the callback:
  #
  #   1. The Paid-initiated flow (the standard SaaS path):
  #      a. The user clicks "Install paid-agents" in the integrations UI.
  #      b. `GET /github_app/install` mints a CSRF state, stores it in the
  #         session, and 302s to GitHub's install URL with `state=...`.
  #      c. After install, GitHub redirects to
  #         `GET /github_app/callback?installation_id=...&setup_action=...&state=...`.
  #         The controller verifies the CSRF state, then enqueues
  #         `Github::Installations::SyncJob`.
  #
  #   2. The GitHub-initiated flow (post-install or post-update from a manifest
  #      App that has `setup_url` set, e.g. self-hosted deployments):
  #      GitHub redirects to `setup_url` with `installation_id` and
  #      `setup_action` but no `state`. The user lands here without having gone
  #      through `/github_app/install`, so the session has no state to verify.
  #      In that case the callback skips the CSRF check but still defers to
  #      `SyncJob`, which only binds when the JWT-fetched installation matches
  #      a trusted signal (existing row or matching project owner). Otherwise
  #      binding is deferred to the signed `installation` webhook.
  #
  # Note: GitHub's setup URL `installation_id` parameter is spoofable — a
  # signed-in user could complete the local callback with an installation_id
  # they do not actually own. The CSRF `state` only proves the user clicked
  # Paid's install button, not that they completed the GitHub side of the
  # flow. The actual binding is gated inside `SyncJob` against trusted
  # signals (an existing `GithubInstallation` row, or a project owner in
  # the account that matches the installation's `account.login`). When
  # neither holds, the SyncJob defers binding to the signed `installation`
  # webhook — the trusted path.
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
      # Capture the account before clearing the session state so the value
      # stored at install time survives into the SyncJob. When GitHub redirects
      # via `setup_url` (no prior /install call), the session has no state and
      # we fall back to the currently signed-in account.
      account_id = session_account_id || current_account.id

      clear_install_state!

      if installation_id.zero?
        redirect_to integrations_path, alert: "Missing installation_id from GitHub callback."
        return
      end

      Github::Installations::SyncJob.perform_later(
        installation_id: installation_id,
        account_id: account_id,
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

    # Validates the CSRF `state` minted by `install`. When no state is present
    # in the session — for example, GitHub's `setup_url` redirected here
    # directly without the user going through `/install` first — we let the
    # request through and rely on `SyncJob`'s binding verification to gate
    # persistence. When a state IS present (Paid-initiated flow), it must match
    # the request-supplied `state` parameter, otherwise we reject the request.
    def verify_install_state!
      stored = install_state

      if stored.blank?
        # GitHub-initiated redirect — defer binding verification to SyncJob.
        return
      end

      if params[:state].to_s.blank? ||
          !ActiveSupport::SecurityUtils.secure_compare(install_state_value(stored, :token).to_s, params[:state].to_s)
        clear_install_state!
        redirect_to integrations_path, alert: "GitHub App installation state did not match."
        return
      end

      if install_state_value(stored, :issued_at).to_i < (Time.current - INSTALL_STATE_TTL).to_i
        clear_install_state!
        redirect_to integrations_path, alert: "GitHub App installation request expired. Please try again."
      end
    end

    def clear_install_state!
      session.delete(INSTALL_STATE_SESSION_KEY)
    end

    def session_account_id
      stored = install_state
      install_state_value(stored, :account_id)
    end

    # The session hash stored during `install` uses symbol keys, but the
    # encrypted cookie is JSON-serialized so the hash comes back with string
    # keys on the next request. Accept either so the controller works
    # regardless of which side of the cookie round-trip it runs on.
    def install_state
      stored = session[INSTALL_STATE_SESSION_KEY]
      stored.is_a?(Hash) ? stored : nil
    end

    def install_state_value(stored, key)
      return nil if stored.blank?

      stored[key] || stored[key.to_s]
    end
  end
end
