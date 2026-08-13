# frozen_string_literal: true

module Configuration
  module Profiles
    # Raised when a profile plan has unmet prerequisites and cannot be applied.
    class BlockedError < StandardError; end
  end
end
