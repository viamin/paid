# frozen_string_literal: true

module Notifications
  module Rules
    # Surfaces a project whose code-scanning scan cannot proceed because the
    # project lacks required configuration (no trusted GitHub usernames).
    # Auto-resolves on the next successful scan_security_alerts_activity call
    # when the operator fixes the underlying configuration.
    # @spec EAGER-QUEUE-016
    class CodeScanningConfigurationError < Rule
      SOURCE = "code_scanning_configuration_error"

      def source = SOURCE

      def detect(scope)
        Array(scope).select do |project|
          next false unless project.security_alert_types.include?("code_scanning")

          !SecurityAlerts::ProcessCodeScanningAlerts.trusted_login_configured?(project)
        end
      end

      def resolve_candidates(scope)
        Array(scope)
      end

      def build(project)
        path = edit_project_path(project)
        {
          severity: :error,
          blocking: true,
          title: "Code scanning is misconfigured",
          description: "Add at least one trusted GitHub username in Project Settings so Paid can create synthetic issues for code scanning alerts.",
          nav_section: "projects",
          action_url: path,
          metadata: {
            project_id: project.id,
            recommended_action: "Open Project Settings -> Trusted GitHub Users and add the username(s) Paid should treat as authoritative for code scanning alerts.",
            remediation_steps: [
              "Open the project's settings page.",
              "Add one or more trusted GitHub usernames (the account owner, or a known Paid bot).",
              "Re-run the code-scanning scan after the change."
            ],
            remediation_context: {
              project_path: path,
              allowed_github_usernames: Array(project.allowed_github_usernames).compact
            }.compact
          }
        }
      end
    end
  end
end
