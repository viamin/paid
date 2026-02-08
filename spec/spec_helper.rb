# frozen_string_literal: true

require "simplecov"
SimpleCov.start "rails" do
  minimum_coverage 80
  add_filter "/spec/"
  add_filter "/config/"
  add_filter "/vendor/"
end

RSpec.configure do |config|
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
