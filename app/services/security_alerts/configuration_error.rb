# frozen_string_literal: true

module SecurityAlerts
  # Raised when a project lacks required configuration for security alert processing
  # (e.g. no trusted GitHub usernames configured).
  class ConfigurationError < StandardError; end
end
