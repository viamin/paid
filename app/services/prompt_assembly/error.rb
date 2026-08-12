# frozen_string_literal: true

module PromptAssembly
  # Base class for all prompt assembly failures. These are non-retryable
  # business-rule errors: retrying will not change the outcome, so they fail
  # loudly before an agent starts rather than limping along.
  class Error < StandardError; end

  # An included section is missing its trust metadata (trust level or source).
  class MissingTrustMetadata < Error; end

  # A section's trust level is not one of PromptAssembly::Trust::TRUST_LEVELS.
  class UnknownTrustLevel < Error; end

  # A section declares a render mode its trust level does not permit.
  class IncompatibleRenderMode < Error; end

  # A section is missing its stable key.
  class MissingSectionKey < Error; end

  # A section is missing its inclusion reason.
  class MissingInclusionReason < Error; end

  # An ordinary profile attempted to disable a safety-sensitive section.
  class SafetySectionDisabled < Error; end
end
