# frozen_string_literal: true

module PromptAssembly
  # A section's trust level is not one of PromptAssembly::Trust::TRUST_LEVELS.
  class UnknownTrustLevel < Error; end
end
