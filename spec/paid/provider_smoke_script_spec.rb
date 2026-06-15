# frozen_string_literal: true

require "rails_helper"
require "open3"

class ProviderSmokeScript < Pathname
end

RSpec.describe ProviderSmokeScript, :no_db do
  def run_script(*args)
    Open3.capture3(
      {
        "RAILS_ENV" => "test",
        "SECRET_KEY_BASE" => "test-secret-key-base"
      },
      "bundle", "exec", "ruby", "bin/provider-smoke", *args,
      chdir: Rails.root.to_s
    )
  end

  it "lists Pi-specific providers with their configured API key env vars" do
    stdout, stderr, status = run_script("list")

    expect(status.success?).to be(true), stderr
    expect(stdout).to include("pi:")
    expect(stdout).to include("google         GEMINI_API_KEY")
  end

  it "rejects providers that are unsupported for the selected runner" do
    _stdout, stderr, status = run_script("zai_coding", "glm-5.2", "pi")

    expect(status.success?).to be(false)
    expect(stderr).to include('Unsupported provider "zai_coding" for pi.')
    expect(stderr).to include("Supported: anthropic, openai, deepseek, google, mistral, minimax, xai, zai, openrouter")
  end
end
