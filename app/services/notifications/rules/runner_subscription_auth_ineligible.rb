# frozen_string_literal: true

module Notifications
  module Rules
    # Publishes a blocking notification when a subscription runner can no
    # longer authenticate on any backend. Auth eligibility mirrors the
    # scheduler's auth-source resolution
    # (Containers::ResolveHostForRun#subscription_auth_source_for) evaluated
    # by Runners::SubscriptionAuthEligibility against the most permissive
    # backend: a managed credential is the primary path, but runners with an
    # API-key proxy (Codex) or host-forwarded fallback (Claude, Codex, Gemini,
    # Copilot) can still authenticate without one. Only providers without any
    # fallback path (OpenCode, Omp) surface `managed_auth_missing` when their
    # managed credential is gone.
    class RunnerSubscriptionAuthIneligible < Rule
      SOURCE = "runner_subscription_auth_ineligible"
      REASONS = %i[credential_expired credential_refresh_failed managed_auth_missing].freeze

      API_KEY_PROXY_SUBSCRIPTION_RUNNERS = %w[codex].freeze
      HOST_FORWARDED_SUBSCRIPTION_RUNNERS = %w[claude codex gemini copilot].freeze

      # A runner that cannot authenticate on a local, host-path-capable
      # backend with a reachable proxy is blocked on every backend.
      LOCAL_BACKEND = Struct.new(:identifier, :supports_host_paths?).new("local", true).freeze

      private

      def source = SOURCE

      # @spec NOTIFICATION-SEVERITY-011
      def build(runner)
        reason = ineligible_reason_for(runner)

        {
          severity: :error,
          blocking: true,
          title: "#{runner.display_name} can't authenticate - #{reason_label(reason)}",
          description: "Future runs on this subscription runner are blocked until its managed credential is fixed.",
          nav_section: "runners",
          action_url: edit_runner_path(runner),
          metadata: {
            reason: reason.to_s,
            runner_key: runner.runner_key,
            recommended_action: "Re-authenticate this runner in Runner Settings so future runs can authenticate again.",
            remediation_steps: [
              "Open Runner Settings for this runner.",
              "Reconnect or replace the managed credential for the runner.",
              "Retry the blocked run after the runner shows as authenticated."
            ],
            remediation_context: {
              runner_name: runner.display_name,
              runner_path: edit_runner_path(runner)
            }
          }
        }
      end

      def subscription_runners(scope)
        Array(scope).select(&:subscription?).select { |runner| auth_provider_for(runner).present? }
      end

      def ineligible_reason_for(runner)
        result = Runners::SubscriptionAuthEligibility.call(
          backend: LOCAL_BACKEND,
          auth_source: auth_source_for(runner),
          proxy_reachable: true
        )
        return nil if result.eligible?
        return nil unless result.reason.in?(REASONS)

        result.reason
      end

      def auth_source_for(runner)
        runner_key = runner.runner_key.to_s
        auth_mode = auth_mode_for(runner, runner_key)
        credential = auth_mode == :managed ? latest_credential_for(runner) : nil

        Runners::SubscriptionAuthEligibility::AuthSource.new(
          runner_key: runner_key,
          auth_mode: auth_mode,
          credential_state: credential ? credential_state_for(runner, credential) : nil
        )
      end

      def auth_mode_for(runner, runner_key)
        return :managed if latest_credential_for(runner)
        return :api_key_proxy if API_KEY_PROXY_SUBSCRIPTION_RUNNERS.include?(runner_key)
        return :host_forwarded if HOST_FORWARDED_SUBSCRIPTION_RUNNERS.include?(runner_key)

        :none
      end

      def credential_state_for(runner, credential)
        return :refresh_failed if latest_refresh_failed?(runner, credential)
        return :expired if credential_expired?(runner, credential)

        :active
      end

      def credential_expired?(runner, credential)
        return true if credential.revoked?

        status = auth_provider_for(runner)&.status(secret: credential.token.to_s)
        status&.expired? || credential.expired?
      end

      def latest_refresh_failed?(runner, credential)
        latest_refresh_attempts.fetch(refresh_attempt_key(runner, credential), nil)&.result == RunnerAuthAttempt::RESULT_REFRESH_FAILED
      end

      def latest_credential_for(runner)
        latest_credentials[credential_key(runner)]
      end

      def latest_credentials
        @latest_credentials ||= begin
          runners = @current_scope_runners || []
          credentials = RunnerCredential
            .where(account_id: runners.map { |runner| runner.user.account_id }.uniq, runner_key: runners.map(&:runner_key).uniq, auth_kind: "oauth_token")
            .order(created_at: :desc, id: :desc)

          credentials.each_with_object({}) do |credential, indexed|
            key = [ credential.account_id, credential.runner_key ]
            indexed[key] ||= credential
          end
        end
      end

      def latest_refresh_attempts
        @latest_refresh_attempts ||= begin
          credentials = latest_credentials.values
          return {} if credentials.empty?

          RunnerAuthAttempt
            .where(runner_credential_id: credentials.map(&:id), attempt_stage: RunnerAuthAttempt::STAGE_REFRESH)
            .order(attempted_at: :desc, id: :desc)
            .each_with_object({}) do |attempt, indexed|
              key = [ attempt.account_id, attempt.runner_key, attempt.runner_credential_id ]
              indexed[key] ||= attempt
            end
        end
      end

      # @spec NOTIFICATION-SEVERITY-011
      def detect(scope)
        @current_scope_runners = subscription_runners(scope)
        @current_scope_runners.select { |runner| ineligible_reason_for(runner).present? }
      end

      def refresh_attempt_key(runner, credential)
        [ runner.user.account_id, runner.runner_key, credential.id ]
      end

      def credential_key(runner)
        [ runner.user.account_id, runner.runner_key ]
      end

      def auth_provider_for(runner)
        Runners::SubscriptionAuthProviders.for_runner(runner.runner_key)
      end

      def reason_label(reason)
        case reason
        when :credential_expired then "managed credential expired"
        when :credential_refresh_failed then "managed credential refresh failed"
        when :managed_auth_missing then "managed credential missing"
        else reason.to_s.humanize.downcase
        end
      end
    end
  end
end
