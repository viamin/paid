# frozen_string_literal: true

ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)
if ENV["RAILS_ENV"] == "test" && ENV["RAILS_TEST_KEY"].to_s != "" && ENV["RAILS_MASTER_KEY"].to_s == ""
  ENV["RAILS_MASTER_KEY"] = ENV["RAILS_TEST_KEY"]
end

require "bundler/setup" # Set up gems listed in the Gemfile.
require "bootsnap/setup" # Speed up boot time by caching expensive operations.
