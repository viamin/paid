# frozen_string_literal: true

module Notifications
  module Rules
    # Surfaces a project whose GitHub token cannot read code-scanning alerts
    # because the App/PAT is missing the `code_scanning_alerts:read` (fine
    # grained) or `security_events` (classic) scope. Auto-resolves on the next
    # successful scan_security_alerts_activity call when the operator fixes
    # the credential.
    # @spec EAGER-QUEUE-016
    class CodeScanningPermissionsError < Rule
      SOURCE = "code_scanning_permissions_error"

      def source = SOURCE

      def detect(scope)
        Array(scope).select do |project|
          project.security_alert_types.include?("code_scanning") &&
            project.code_scanning_permission_error_at.present? &&
            project.code_scanning_permission_error_at > backoff.ago
        end
      end

      def resolve_candidates(scope)
        Array(scope).select { |project| project.security_alert_types.include?("code_scanning") }
      end

      def build(project)
        path = edit_project_path(project)
        {
          severity: :error,
          blocking: true,
          title: "Code scanning token lacks permission",
          description: build_description(project),
          nav_section: "projects",
          action_url: path,
          metadata: {
            project_id: project.id,
            permission_error_at: project.code_scanning_permission_error_at&.iso8601,
            recommended_action: "Re-authorize the GitHub App or rotate the PAT so it has code_scanning_alerts:read (fine-grained) or security_events (classic) scope, then re-run the scan.",
            remediation_steps: [
              "Open Project Settings -> GitHub integration.",
              "Re-authorize or rotate the token so it has code_scanning_alerts:read (fine-grained PAT) or security_events (classic PAT) scope.",
              "Wait for the next scan; the notification auto-resolves once the scan succeeds."
            ],
            remediation_context: {
              project_path: path
            }
          }
        }
      end

      private

      def backoff
        Activities::ScanSecurityAlertsActivity::PERMISSION_ERROR_BACKOFF
      end

      def edit_project_path(project)
        "/projects/#{project.id}/edit"
      end

      def build_description(_project)
        "Re-authorize the GitHub App or rotate the PAT with code-scanning read permission, then wait for the next scan to confirm access."
      end
    end
  end
end
