# frozen_string_literal: true

module Notifications
  module Rules
    class RunnerSubscriptionAuthIneligible < Rule
      SOURCE = "runner_subscription_auth_ineligible"
      REASONS = %i[credential_expired credential_refresh_failed managed_auth_missing].freeze

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
        return :managed_auth_missing unless (credential = latest_credential_for(runner))
        return :credential_refresh_failed if latest_refresh_failed?(runner, credential)
        return :credential_expired if credential_expired?(runner, credential)

        nil
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
