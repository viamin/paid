# frozen_string_literal: true

require "rails_helper"
require "open3"

class BootFile < Pathname
end

RSpec.describe BootFile, :no_db do
  let(:boot_script) do
    <<~RUBY
      require_relative "config/boot"
      puts ENV.fetch("RAILS_MASTER_KEY", "")
    RUBY
  end

  let(:environment_boot_script) do
    <<~RUBY
      ENV["SECRET_KEY_BASE"] ||= "test-secret-key-base"
      require_relative "config/environment"
      puts Rails.application.credentials.to_h.inspect
    RUBY
  end

  it "aliases RAILS_TEST_KEY to RAILS_MASTER_KEY in test when the master key is unset" do
    stdout, stderr, status = Open3.capture3(
      {
        "RAILS_ENV" => "test",
        "RAILS_TEST_KEY" => "test-master-key",
        "RAILS_MASTER_KEY" => nil
      },
      "bundle", "exec", "ruby", "-e", boot_script,
      chdir: Rails.root.to_s
    )

    expect(status.success?).to be(true), stderr
    expect(stdout.strip).to eq("test-master-key")
  end

  it "does not override an existing RAILS_MASTER_KEY" do
    stdout, stderr, status = Open3.capture3(
      {
        "RAILS_ENV" => "test",
        "RAILS_TEST_KEY" => "test-master-key",
        "RAILS_MASTER_KEY" => "already-set"
      },
      "bundle", "exec", "ruby", "-e", boot_script,
      chdir: Rails.root.to_s
    )

    expect(status.success?).to be(true), stderr
    expect(stdout.strip).to eq("already-set")
  end

  it "treats blank test key env vars as absent" do
    stdout, stderr, status = Open3.capture3(
      {
        "RAILS_ENV" => "test",
        "RAILS_TEST_KEY" => "",
        "RAILS_MASTER_KEY" => ""
      },
      "bundle", "exec", "ruby", "-e", boot_script,
      chdir: Rails.root.to_s
    )

    expect(status.success?).to be(true), stderr
    expect(stdout.strip).to eq("")
  end

  it "does not alias the test key outside the test environment" do
    stdout, stderr, status = Open3.capture3(
      {
        "RAILS_ENV" => "development",
        "RAILS_TEST_KEY" => "test-master-key",
        "RAILS_MASTER_KEY" => nil
      },
      "bundle", "exec", "ruby", "-e", boot_script,
      chdir: Rails.root.to_s
    )

    expect(status.success?).to be(true), stderr
    expect(stdout.strip).to eq("")
  end

  it "boots the test environment without credential keys by treating test credentials as optional" do
    stdout, stderr, status = Open3.capture3(
      {
        "RAILS_ENV" => "test",
        "RAILS_TEST_KEY" => nil,
        "RAILS_MASTER_KEY" => nil,
        "SECRET_KEY_BASE" => "test-secret-key-base"
      },
      "bundle", "exec", "ruby", "-e", environment_boot_script,
      chdir: Rails.root.to_s
    )

    expect(status.success?).to be(true), stderr
    expect(stdout.strip).to eq("{}")
  end
end
