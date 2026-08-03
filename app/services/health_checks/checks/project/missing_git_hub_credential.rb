# frozen_string_literal: true

module HealthChecks
  module Checks
    module Project
      class MissingGitHubCredential < HealthChecks::Check
        self.scope = :project

        def self.network? = false

        def call
          return [] if subject.github_token.present? || subject.github_installation.present?

          finding(
            severity: :error,
            title: "Missing GitHub credentials",
            description: "The project has neither a GitHub App installation nor a personal access token, so Paid cannot access the repository.",
            remediation: "Configure a GitHub App installation or a personal access token.",
            action_url: settings_action_url(:edit_project_path, anchor: "github-authentication")
          )
        end
      end
    end
  end
end
