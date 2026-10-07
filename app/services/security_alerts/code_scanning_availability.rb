# frozen_string_literal: true

module SecurityAlerts
  class CodeScanningAvailability
    EXPLICIT_UNAVAILABLE_MESSAGES = [
      "code scanning is not enabled",
      "code scanning is unavailable",
      "code scanning is not available",
      "code scanning is not supported"
    ].freeze

    Result = Data.define(:status) do
      def available? = status == :available

      def unavailable? = status == :unavailable
    end

    def self.call(...) = new(...).call

    def self.unavailable_response?(error)
      explicit_unavailable_message?(error) &&
        (error.is_a?(GithubClient::NotFoundError) || error.status == 403)
    end

    def self.disable(project:, reason:)
      project.update_columns(
        security_alert_types: project.security_alert_types - [ "code_scanning" ],
        code_scanning_scan_error_kind: "unavailable",
        code_scanning_scan_error_reason: AgentRun::ErrorMessageSanitizer.call(text: reason),
        code_scanning_permission_error_at: nil,
        next_code_scanning_scan_at: nil
      )
      resolve_permission_notification(project)
    end

    def self.resolve_permission_notification(project)
      notification = Notification.active.find_by(
        account: project.account,
        source: Notifications::Rules::CodeScanningPermissionsError::SOURCE,
        subject: project
      )
      return unless notification

      Notifications::Resolve.call(account: project.account, source: notification.source, subject: project)
    end

    def initialize(project:, enable:)
      @project = project
      @enable = enable
    end

    # @spec GITHUB-SYNC-020
    def call
      project.client.code_scanning_alerts(project.full_name, default_branch: project.default_branch)
      enable_code_scanning if enable
      clear_unavailable_state
      Result.new(:available)
    rescue GithubClient::ApiError, GithubClient::NotFoundError => e
      raise unless self.class.unavailable_response?(e)

      self.class.disable(project:, reason: e.message)
      Result.new(:unavailable)
    end

    private

    attr_reader :project, :enable

    def enable_code_scanning
      project.update_columns(security_alert_types: (project.security_alert_types | [ "code_scanning" ]))
    end

    def self.explicit_unavailable_message?(error)
      EXPLICIT_UNAVAILABLE_MESSAGES.any? { |message| error.message.downcase.include?(message) }
    end

    def clear_unavailable_state
      return unless project.code_scanning_scan_error_kind == "unavailable"

      project.update_columns(
        code_scanning_scan_error_kind: nil,
        code_scanning_scan_error_reason: nil,
        next_code_scanning_scan_at: nil
      )
    end
  end
end
