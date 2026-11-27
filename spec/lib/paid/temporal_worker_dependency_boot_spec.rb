# frozen_string_literal: true

require "spec_helper"
require "bundler"
require "open3"
require "rbconfig"

RSpec.describe "Temporal worker dependency boot" do # rubocop:disable RSpec/DescribeClass
  # @spec TEMPORAL-ORCHESTRATION-024
  it "activates the locked dependencies before readiness helpers load JSON" do
    root = File.expand_path("../../..", __dir__)
    worker = File.join(root, "bin/temporal_worker")
    source = <<~RUBY
      worker = #{worker.inspect}
      prefix = File.read(worker).split("\nrequire_relative \\\"../config/environment\\\"", 2).first
      eval(prefix, TOPLEVEL_BINDING, worker)
      require "bundler/setup"
      puts JSON::VERSION
    RUBY
    env = Bundler.unbundled_env.merge("BUNDLE_GEMFILE" => File.join(root, "Gemfile"), "RAILS_ENV" => "test")
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-e", source, unsetenv_others: true)

    expect(status.success?).to be(true), stderr
    expect(stdout).to match(/\A2\./)
  end
end
