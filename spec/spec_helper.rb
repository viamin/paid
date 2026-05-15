# frozen_string_literal: true

coverage_enabled = if ENV.key?("COVERAGE")
  ENV["COVERAGE"] != "false"
else
  # DB-less verification runs intentionally execute only a small subset of the
  # suite, so enforcing the global coverage floor there creates false failures.
  ENV["ALLOW_DBLESS_SPECS"] != "true"
end

if coverage_enabled
  require "simplecov"
  SimpleCov.start "rails" do
    minimum_coverage 80
    add_filter "/spec/"
    add_filter "/config/"
    add_filter "/vendor/"
  end
end

require "test_prof"

TestProf.configure do |config|
  config.output_dir = "tmp/test_prof"
  config.timestamps = true
end

module Warning
  APP_WARNING_PATHS = %w[app config lib spec].map do |path|
    File.expand_path(path, File.expand_path("..", __dir__))
  end.freeze
  private_constant :APP_WARNING_PATHS

  GEM_WARNING_PATHS ||= (
    Gem.path + [ Gem.default_dir, Gem.user_dir ]
  ).flat_map do |path|
    [ File.join(path, "gems"), File.join(path, "bundler", "gems") ]
  end.map { |path| File.expand_path(path) }
    .uniq
    .freeze
  private_constant :GEM_WARNING_PATHS

  class << self
    unless method_defined?(:warn_without_gem_noise)
      alias_method :warn_without_gem_noise, :warn

      def warn(message, category: nil, **kwargs)
        return if gem_warning?(message)

        warn_without_gem_noise(message, category: category, **kwargs)
      end

      private

      def gem_warning?(message)
        paths = warning_paths(message)
        return false if paths.empty?
        return false if app_warning?(paths)

        paths.any? do |source_path|
          GEM_WARNING_PATHS.any? { |path| source_path.start_with?("#{path}/") }
        end
      end

      def app_warning?(paths)
        paths.any? do |source_path|
          APP_WARNING_PATHS.any? { |path| source_path.start_with?("#{path}/") }
        end
      end

      def warning_paths(message)
        warning_line = message.lines.first.to_s
        warning_line.scan(%r{/(?:[^:\s]|:(?!\d))+}).map { |path| File.expand_path(path) }.uniq
      end
    end
  end
end

RSpec.configure do |config|
  config.example_status_persistence_file_path = "spec/.examples.txt"

  if ENV["GITHUB_ACTIONS"] == "true"
    require "rspec/github"
    config.add_formatter RSpec::Github::Formatter
  end

  # rspec-expectations config goes here.
  config.expect_with :rspec do |expectations|
    # This option will default to `true` in RSpec 4.
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  # rspec-mocks config goes here.
  config.mock_with :rspec do |mocks|
    # Prevents you from mocking or stubbing a method that does not exist on
    # a real object.
    mocks.verify_partial_doubles = true
  end

  # This option will default to `:apply_to_host_groups` in RSpec 4.
  config.shared_context_metadata_behavior = :apply_to_host_groups

  # Limits the available syntax to the non-monkey patched syntax.
  config.disable_monkey_patching!

  # This setting enables warnings.
  config.warnings = true

  # Print the 10 slowest examples at the end of the spec run.
  config.profile_examples = 10 if config.files_to_run.one?

  # Run specs in random order to surface order dependencies.
  config.order = :random

  # Seed global randomization in this process using the `--seed` CLI option.
  Kernel.srand config.seed
end
