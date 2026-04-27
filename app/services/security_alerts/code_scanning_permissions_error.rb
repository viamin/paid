# frozen_string_literal: true

module SecurityAlerts
  # Raised when the GitHub token cannot read code scanning alerts because the
  # required permission or scope is missing.
  class CodeScanningPermissionsError < ConfigurationError; end
end
