# frozen_string_literal: true

require "json"
require "open3"
require "rails_helper"
require "rbconfig"

class TestEnvironmentLogging
end

RSpec.describe TestEnvironmentLogging, :no_db do
  # @spec TEST-SUITE-028
  it "omits SQL debug output by default while retaining application messages" do
    log = boot_and_capture_log

    expect(log).to include(
      "application info",
      "application warning",
      "application error"
    )
    expect(log).not_to include("SELECT 1")
  end

  # @spec TEST-SUITE-028
  it "emits SQL debug output when RAILS_LOG_LEVEL is debug" do
    log = boot_and_capture_log("RAILS_LOG_LEVEL" => "debug")

    expect(log).to include(
      "application info",
      "application warning",
      "application error",
      "SELECT 1"
    )
  end

  private

  def boot_and_capture_log(environment = {})
    stdout, stderr, status = Open3.capture3(
      test_environment.merge(environment),
      RbConfig.ruby,
      "-e",
      logging_script,
      chdir: Rails.root.to_s
    )

    expect(status.success?).to be(true), stderr
    JSON.parse(stdout).fetch("log")
  end

  def test_environment
    { "RAILS_ENV" => "test", "RAILS_LOG_LEVEL" => nil }
  end

  def logging_script
    <<~RUBY
      require "json"
      require "stringio"
      require_relative "config/environment"

      output = StringIO.new
      logger = ActiveSupport::Logger.new(output)
      logger.level = Rails.logger.level
      Rails.logger = logger
      ActiveRecord::Base.logger = logger

      Rails.logger.info("application info")
      Rails.logger.warn("application warning")
      Rails.logger.error("application error")
      ActiveRecord::Base.connection.execute("SELECT 1")

      puts JSON.generate(log: output.string)
    RUBY
  end
end
