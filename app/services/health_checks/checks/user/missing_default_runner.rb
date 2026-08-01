# frozen_string_literal: true

module HealthChecks
  module Checks
    module User
      class MissingDefaultRunner < HealthChecks::Check
        self.scope = :user

        def self.network? = false

        def call
          return [] if settings.blank?
          return [] if default_runner.blank?
          return [] unless stale_runner_reference?(default_runner)
          return [] if valid_default_runner?(default_runner)

          finding(
            severity: :warning,
            message: "Default agent runner references a disabled or discarded runner: #{default_runner}."
          )
        end

        private

        def valid_default_runner?(identifier)
          settings.send(
            :identifiers_for_runner_token,
            identifier,
            candidates: settings.send(:allowed_runner_identifiers_for_agent_runs)
          ).present?
        end

        def stale_runner_reference?(identifier)
          Runner.for_identifier(owner, identifier, include_discarded: true).present?
        end

        def default_runner
          settings.default_agent_runner.to_s.presence
        end

        def settings
          @settings ||= if subject.is_a?(::Project)
            AgentRuns::UserSettingsResolver.call(project: subject, strict: false, create: false)
          else
            owner&.user_setting
          end
        end

        def owner
          subject.is_a?(::Project) ? subject.effective_owner : subject
        end
      end
    end
  end
end
