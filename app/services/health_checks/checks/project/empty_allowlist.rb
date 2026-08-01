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
            title: "Trusted usernames allowlist is empty",
            description: "No trusted GitHub usernames are configured, so no issues will be treated as trusted.",
            remediation: "Add at least one trusted GitHub username.",
            action_url: settings_action_url(:edit_project_path, anchor: "trusted-usernames")
          )
        end
      end
    end
  end
end
