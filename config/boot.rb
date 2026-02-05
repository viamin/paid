# frozen_string_literal: true

# Filter out warnings from third-party gems (method redefinitions, deprecations, circular requires).
# Applied early in boot to catch warnings during Bundler.require.
module WarningFilter
  IGNORED_PATTERNS = [
    %r{/gems/.*: warning: method redefined},
    %r{/gems/.*: warning: previous definition of},
    /circular require considered harmful.*\/gems\//,
    %r{/gems/.*: warning:.*is obsolete}
  ].freeze

  def warn(message, ...)
    return if IGNORED_PATTERNS.any? { |pattern| pattern.match?(message) }

    super
  end
end
Warning.extend(WarningFilter)

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" # Set up gems listed in the Gemfile.
require "bootsnap/setup" # Speed up boot time by caching expensive operations.
