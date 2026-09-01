# frozen_string_literal: true

# Resolves the Chromium/Chrome binary for Cuprite system specs. Included into
# `type: :system` examples and callable directly so the driver registration in
# `spec/support/capybara.rb` and per-spec skip guards resolve the same binary.
module ChromiumAvailability
  extend self

  CHROMIUM_CANDIDATE_PATHS = %w[
    /usr/bin/chromium
    /usr/bin/chromium-browser
    /usr/bin/google-chrome
    /usr/bin/google-chrome-stable
  ].freeze

  def chromium_path
    return @chromium_path if defined?(@chromium_path)

    configured = ENV["CHROMIUM_PATH"]
    @chromium_path =
      if configured.present? && File.executable?(configured)
        configured
      else
        CHROMIUM_CANDIDATE_PATHS.find { |path| File.executable?(path) }
      end
  end
end

RSpec.configure do |config|
  config.include ChromiumAvailability, type: :system
end
