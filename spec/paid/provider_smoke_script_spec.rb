# frozen_string_literal: true

require "rails_helper"
require "open3"
require "rbconfig"
require "tmpdir"

class ProviderSmokeScript < Pathname
end

RSpec.describe ProviderSmokeScript, :no_db do
  # @spec TEST-SUITE-010
  def run_script(*args)
    Dir.mktmpdir("provider-boot-probe") do |dir|
      probe = File.join(dir, "boot_probe.rb")
      File.write(probe, 'at_exit { warn "RAILS_BOOTED=#{defined?(Rails::Application) ? true : false}" }')
      Open3.capture3(
        {
          "RAILS_ENV" => "test",
          "SECRET_KEY_BASE" => "test-secret-key-base",
          "RUBYOPT" => "-r#{probe}"
        },
        RbConfig.ruby, "bin/provider-smoke", *args,
        chdir: Rails.root.to_s
      )
    end
  end

  it "lists Pi-specific providers with their configured API key env vars" do
    stdout, stderr, status = run_script("list")

    expect(status.success?).to be(true), stderr
    expect(stderr).to include("RAILS_BOOTED=false")
    expect(stdout).to include("pi:")
    expect(stdout).to include("google         GEMINI_API_KEY")
  end

  it "rejects providers that are unsupported for the selected runner" do
    _stdout, stderr, status = run_script("zai_coding", "glm-5.2", "pi")

    expect(status.success?).to be(false)
    expect(stderr).to include("RAILS_BOOTED=false")
    expect(stderr).to include('Unsupported provider "zai_coding" for pi.')
    expect(stderr).to include("Supported: anthropic, openai, deepseek, google, mistral, minimax, xai, zai, openrouter")
  end

  it "shows help without booting Rails" do
    stdout, stderr, status = run_script("--help")

    expect(status.exitstatus).to eq(0)
    expect(stdout).to include("Usage:")
    expect(stderr).to include("RAILS_BOOTED=false")
  end

  it "rejects a missing model without booting Rails" do
    _stdout, stderr, status = run_script("anthropic")

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("Both <provider> and <model> are required.", "RAILS_BOOTED=false")
  end

  it "rejects an unsupported runner without booting Rails" do
    _stdout, stderr, status = run_script("anthropic", "test-model", "unknown")

    expect(status.exitstatus).to eq(1)
    expect(stderr).to include("Unsupported runner_key", "RAILS_BOOTED=false")
  end
end
