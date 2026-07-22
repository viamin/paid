# frozen_string_literal: true

module Configuration
  module Profiles
    # Raised when the actor lacks permission for one or more profile changes.
    class UnauthorizedError < StandardError; end
  end
end
