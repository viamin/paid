# frozen_string_literal: true

module SecurityAlerts
  # Raised when Dependabot alerts are unavailable because the GitHub token lacks
  # permission or alert access is disabled for the repository.
  class DependabotPermissionsError < ConfigurationError; end
end
