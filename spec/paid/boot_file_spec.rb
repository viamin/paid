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
end
