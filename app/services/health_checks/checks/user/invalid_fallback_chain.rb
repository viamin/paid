# frozen_string_literal: true

module HealthChecks
  module Checks
    module User
      class InvalidFallbackChain < HealthChecks::Check
        self.scope = :user

        def self.network? = false

        def call
          return [] if settings.blank?

          invalid = invalid_fallback_runners
          return [] if invalid.empty?

          finding(
            severity: :warning,
            message: "Fallback runner chain references disabled or discarded runners: #{invalid.join(', ')}."
          )
        end

        private

        def invalid_fallback_runners
          Array(settings.fallback_runners).filter_map do |identifier|
            next if identifier.blank?
            next unless stale_runner_reference?(identifier)
            next if valid_fallback_identifier?(identifier)

            identifier
          end
        end

        def valid_fallback_identifier?(identifier)
          settings.send(
            :identifiers_for_runner_token,
            identifier,
            candidates: settings.send(:allowed_runner_identifiers_for_fallback)
          ).present?
        end

        def stale_runner_reference?(identifier)
          ::Runner.for_identifier(owner, identifier, include_discarded: true).present?
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
