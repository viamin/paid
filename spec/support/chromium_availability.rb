# frozen_string_literal: true

module ChromiumAvailability
  CHROMIUM_CANDIDATE_PATHS = %w[
    /usr/bin/chromium
    /usr/bin/chromium-browser
    /usr/bin/google-chrome
    /usr/bin/google-chrome-stable
  ].freeze

  def chromium_path
    @chromium_path ||= begin
      configured = ENV["CHROMIUM_PATH"]
      return configured if configured.present? && File.executable?(configured)

      CHROMIUM_CANDIDATE_PATHS.find { |path| File.executable?(path) }
    end
  end
end

RSpec.configure do |config|
  config.include ChromiumAvailability, type: :system
end
