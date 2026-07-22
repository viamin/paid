# frozen_string_literal: true

module Configuration
  module Profiles
    # Raised when an override references a key the profile did not declare.
    class UnknownOverrideError < ArgumentError; end
  end
end
