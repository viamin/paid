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
  #         The controller verifies the CSRF state, then upserts a
  #         `PendingInstallClaim` and enqueues `Github::Installations::SyncJob`.
  #
  #   2. The self-hosted manifest flow: GitHub's `setup_url` redirect hits
  #      the callback with `installation_id` + `setup_action` but no `state`
  #      (no prior `/install` call). The user is signed in as an operator
  #      of the only Paid account on the deployment. The controller
  #      authenticates the operator, upserts a `PendingInstallClaim` tagged
  #      with `source=operator_setup`, and enqueues the SyncJob. Binding is
  #      otherwise deferred to the signed `installation` webhook.
  #
  # In every other case — a non-operator hitting the callback with no
  # session state, or a forged `state` — no claim is created and the
  # SyncJob's secondary-signal check refuses to bind. The webhook's
  # `AccountResolver` likewise refuses to bind without a claim, since the
  # only other signals (existing row, project owner match, prior
  # installation for the same login) cannot resolve an account for a
  # first-time install into a brand-new org.
  #
  # `PendingInstallClaim` is the server-trusted binding signal: it is
  # created on the same request that verifies the user's intent (state CSRF
  # or operator session) and consumed by the signed `installation` webhook
  # to finalize the `GithubInstallation` row. The CSRF `state` itself is
  # anti-CSRF only — it does not bind the returned `installation_id`, so
  # even a verified state does not let `SyncJob` skip its secondary-signal
  # check. Stale claims (past `expires_at`) are skipped so a long-lived
  # claim can never authorize a binding the user did not initiate recently.
  #
  # Webhook-driven lifecycle updates (suspend, repositories added/removed,
  # uninstall) are handled by `GithubApp::WebhooksController`, not here.
  # @spec GITHUB-SYNC-004
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
    # the integrations page.
    def callback
      installation_id = params[:installation_id].to_i
      setup_action = params[:setup_action].presence
      # Capture the account before clearing the session state so the value
      # stored at install time survives into the SyncJob. When GitHub redirects
      # via `setup_url` (no prior /install call), the session has no state and
      # we fall back to the currently signed-in account.
      account_id = session_account_id || current_account&.id

      clear_install_state!

      if installation_id.zero?
        redirect_to integrations_path, alert: "Missing installation_id from GitHub callback."
        return
      end

      claim_source = claim_source_for_callback
      if claim_source && account_id
        PendingInstallClaim.upsert_for_callback!(
          account: Account.find(account_id),
          installation_id: installation_id,
          source: claim_source,
          state_token: @install_state_token
        )
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
    # request through and rely on the operator-self-hosted short-circuit
    # below. When a state IS present (Paid-initiated flow), it must match
    # the request-supplied `state` parameter, otherwise we reject the request.
    def verify_install_state!
      stored = install_state

      if stored.blank?
        # GitHub-initiated redirect — defer binding verification to the
        # operator short-circuit in #callback.
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
        return
      end

      @install_state_verified = true
      @install_state_token = params[:state].to_s
    end

    # Determines whether the current callback should create a
    # PendingInstallClaim. A claim is the server-trusted signal that ties a
    # freshly-returned `installation_id` to a Paid account, and it is the
    # only thing that lets the signed `installation` webhook finalize the
    # `GithubInstallation` row for a first-time install into a brand-new
    # org.
    #
    # Returns the claim source string, or nil when no claim should be
    # created (i.e. the callback arrived with no verifiable user intent).
    def claim_source_for_callback
      return "callback_with_state" if @install_state_verified
      return "operator_setup" if self_hosted_setup_redirect?

      nil
    end

    # The manifest `setup_url` redirect (self-hosted first install into a
    # brand-new org) arrives with no session state. The only signal we have
    # that this is a legitimate operator-initiated install is the operator
    # session: in self-hosted mode the App operator is the only one with
    # admin access to the deployment, and they had to complete the manifest
    # exchange on the same browser to obtain App credentials. A non-operator
    # hitting the callback without session state has no signal we can
    # trust, so we refuse to create a claim — `SyncJob`'s secondary-signal
    # check and the webhook's `AccountResolver` will both decline to bind.
    def self_hosted_setup_redirect?
      return false unless current_user&.operator?
      return false unless Github::AppRegistry.configured?

      install_state.blank?
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
