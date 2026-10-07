# frozen_string_literal: true

module SecurityAlerts
  # Raised when GitHub explicitly confirms that repository code scanning is
  # unavailable. This is an option-state change, not a credential failure.
  class CodeScanningUnavailableError < ConfigurationError; end
end
