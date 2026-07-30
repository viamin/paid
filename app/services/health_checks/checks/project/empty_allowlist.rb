# frozen_string_literal: true

module HealthChecks
  module Checks
    module Project
      class EmptyAllowlist < HealthChecks::Check
        self.scope = :project

        def self.network? = false

        def call
          return [] if Array(subject.allowed_github_usernames).any?(&:present?)

          finding(
            severity: :error,
            message: "Trusted GitHub usernames allowlist is empty."
          )
        end
      end
    end
  end
end
