# frozen_string_literal: true

module Admin
  module GithubApp
    # Self-hosted GitHub App setup via GitHub's app-manifest flow.
    #
    # Flow:
    #   1. Operator visits GET /admin/github_app/setup
    #   2. POST /admin/github_app/setup generates a one-shot manifest and
    #      redirects the operator to GitHub at
    #      `https://github.com/settings/apps/new?manifest=...`.
    #   3. After registering the app on GitHub, GitHub redirects to
    #      GET /admin/github_app/setup/callback with a temporary `code`.
    #   4. The callback exchanges the code for the app's id and PEM private
    #      key, hands the result to `Github::AppCredentialsPersister`, and
    #      either writes the values into the encrypted Rails credentials file
    #      or surfaces the exact snippet the operator must add by hand.
    #
    # Once the App is configured, new projects can use the App-managed
    # auth flow via `GithubApp::InstallationsController`.
    class SetupController < ApplicationController
      include OperatorConsole::RequestContext
      include AuditLogging

      MANIFEST_CALLBACK_PATH = "/admin/github_app/setup/callback".freeze
      MANIFEST_DEFAULT_PERMISSIONS = {
        contents: :write,
        pull_requests: :write,
        issues: :write,
        metadata: :read,
        checks: :read,
        statuses: :read,
        members: :read
      }.freeze

      skip_after_action :verify_authorized, :verify_policy_scoped

      before_action :require_operator!
      before_action :load_state, only: [ :show, :create ]

      # GET /admin/github_app/setup
      def show
        load_configuration_state
      end

      # POST /admin/github_app/setup
      # Generates a one-shot manifest and redirects to GitHub's app creation
      # page. The state token is CSRF protection.
      def create
        state = SecureRandom.urlsafe_base64(32)
        session[:admin_github_app_setup_state] = state

        manifest = build_manifest(state: state)
        encoded = Base64.urlsafe_encode64(manifest.to_json, padding: false)
        redirect_to "https://github.com/settings/apps/new?manifest=#{encoded}", allow_other_host: true
      end

      # GET /admin/github_app/setup/callback
      # GitHub redirects here after the operator registers the App from the
      # manifest. Exchanges the temporary `code` for app id + private key.
      def callback
        expected = session.delete(:admin_github_app_setup_state)
        provided = params[:state].to_s

        if expected.blank? || provided.blank? || !ActiveSupport::SecurityUtils.secure_compare(expected, provided)
          redirect_to admin_github_app_setup_path, alert: "GitHub App setup state did not match."
          return
        end

        code = params[:code].to_s
        if code.blank?
          redirect_to admin_github_app_setup_path, alert: "GitHub did not return a setup code."
          return
        end

        result = Github::AppManifestExchanger.call(code: code)
        persistence = Github::AppCredentialsPersister.call(result: result)

        audit_event(
          "github_app.setup_completed",
          metadata: {
            app_id: result.app_id,
            app_slug: result.slug,
            html_url: result.html_url,
            persistence_status: persistence.status,
            credentials_path: persistence.credentials_path
          }
        )

        render_persistence_outcome(result: result, persistence: persistence)
      rescue Github::AppManifestExchanger::Error => e
        redirect_to admin_github_app_setup_path, alert: "GitHub App setup failed: #{e.message}"
      end

      private

      def require_operator!
        return if current_user&.operator?

        redirect_to root_path, alert: "You are not authorized to manage the GitHub App."
      end

      def load_state
        @state = session[:admin_github_app_setup_state]
      end

      def build_manifest(state:)
        {
          name: manifest_name,
          url: manifest_homepage_url,
          hook_attributes: {
            url: manifest_webhook_url,
            active: true
          },
          redirect_url: manifest_redirect_url(state: state),
          public: false,
          default_events: [ "installation", "installation_repositories" ],
          default_permissions: MANIFEST_DEFAULT_PERMISSIONS
        }
      end

      def manifest_name
        ENV.fetch("PAID_AGENT_APP_NAME", "Paid Agents")
      end

      def manifest_homepage_url
        ENV.fetch("PAID_AGENT_APP_HOMEPAGE_URL", root_url)
      end

      def manifest_webhook_url
        ENV.fetch("PAID_AGENT_APP_WEBHOOK_URL") { default_webhook_url }
      end

      def default_webhook_url
        return "#{root_url.chomp('/')}/api/webhooks/github_app" if root_url.present?

        "https://example.com/api/webhooks/github_app"
      end

      def manifest_redirect_url(state:)
        uri = URI.parse(admin_github_app_setup_callback_url)
        uri.query = { state: state }.to_query
        uri.to_s
      end

      def load_configuration_state
        @configured = Github::AppRegistry.configured?
        @app_slug = Github::AppRegistry.slug
        @app_id = Github::AppRegistry.app_id
        @webhook_secret_configured = Github::AppRegistry.webhook_secret.present?
        @setup_path = admin_github_app_setup_path
      end

      # On a successful persist we can safely redirect — the values are already
      # durably stored. When persistence falls back to `:manual` (read-only
      # credentials file or missing master key), the exchanged PEM and webhook
      # secret are one-time values GitHub will never resend, so we must render
      # them for the operator instead of redirecting them away and dropping the
      # only copy.
      def render_persistence_outcome(result:, persistence:)
        if persistence.persisted?
          redirect_to admin_github_app_setup_path,
            notice: "GitHub App #{result.slug} registered. Credentials written to #{persistence.credentials_path}."
          return
        end

        @registered_slug = result.slug
        @manual_instructions = persistence.manual_instructions
        @manual_credentials_path = persistence.credentials_path
        load_configuration_state
        flash.now[:alert] =
          "GitHub App #{result.slug} registered, but the credentials could NOT be " \
          "saved automatically. Copy the values below to finish setup — GitHub will not show them again."
        render :show, status: :ok
      end
    end
  end
end
