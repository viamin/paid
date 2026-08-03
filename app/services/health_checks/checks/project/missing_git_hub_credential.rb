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
            title: "Project is missing both GitHub App installation and PAT credentials."
          )
        end
      end
    end
  end
end
