# frozen_string_literal: true

module PromptAssembly
  # Base class for all prompt assembly failures. These are non-retryable
  # business-rule errors: retrying will not change the outcome, so they fail
  # loudly before an agent starts rather than limping along.
  #
  # Subclasses live one-per-file (the Zeitwerk/one-class-per-file convention,
  # e.g. app/services/accounts/administration_error.rb) so each error type is
  # autoloadable when referenced directly, such as by +PromptAssembly::Build+
  # at runtime or by specs asserting on a specific failure.
  class Error < StandardError; end
end
