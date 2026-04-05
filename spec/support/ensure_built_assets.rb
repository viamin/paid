# frozen_string_literal: true

module EnsureBuiltAssets
  REQUIRED_ASSETS = %w[application.css application.js].freeze
  BUILD_COMMANDS = [ %w[yarn build], %w[yarn build:css] ].freeze

  module_function

  def ensure!
    return if required_assets_present?

    BUILD_COMMANDS.each do |command|
      success = system({ "TMPDIR" => Rails.root.join("tmp").to_s }, *command, chdir: Rails.root.to_s)
      next if success

      raise "Failed to build test assets with `#{command.join(' ')}`"
    end
  end

  def required_assets_present?
    REQUIRED_ASSETS.all? { |asset| Rails.root.join("app/assets/builds/#{asset}").exist? }
  end
end

RSpec.configure do |config|
  config.before(:suite) do
    EnsureBuiltAssets.ensure!
  end
end
