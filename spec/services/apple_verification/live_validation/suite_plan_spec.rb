# frozen_string_literal: true

require "rails_helper"
require "open3"
require "tmpdir"

# @spec APPLE-LIVE-008
RSpec.describe AppleVerification::LiveValidation::Suite, "#plan" do
  it "prints the fail-closed plan without booting Rails" do
    Dir.mktmpdir("apple-verify-live-spec") do |directory|
      probe_path = File.join(directory, "boot_probe.rb")
      File.write(probe_path, 'at_exit { warn "RAILS_BOOTED=#{defined?(Rails::Application) ? true : false}" }')
      environment = {
        "APPLE_VERIFICATION_HOST_URL" => "",
        "APPLE_VERIFICATION_HOST_TOKEN" => "",
        "APPLE_VERIFICATION_GUEST_EXECUTOR_TOKEN" => "",
        "DATABASE_URL" => "postgresql://unsafe-role@localhost/paid",
        "RUBYOPT" => "-r#{probe_path}"
      }

      stdout, stderr, status = Open3.capture3(environment, script_path, "--plan", chdir: directory)

      expect(status).to be_success, -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("22 scenarios across 8 acceptance criteria.")
      expect(stdout).to include("APPLE_VERIFICATION_HOST_URL is not configured")
      expect(stderr).to include("RAILS_BOOTED=false")
    end
  end

  it "prints a ready plan for a complete request without connecting to the control plane" do
    Dir.mktmpdir("apple-verify-live-spec") do |directory|
      probe_path = File.join(directory, "boot_probe.rb")
      File.write(probe_path, 'at_exit { warn "RAILS_BOOTED=#{defined?(Rails::Application) ? true : false}" }')
      environment = {
        "APPLE_VERIFICATION_HOST_URL" => "https://apple-worker.example.test",
        "APPLE_VERIFICATION_HOST_TOKEN" => "host-token",
        "APPLE_VERIFICATION_GUEST_EXECUTOR_TOKEN" => "guest-token",
        "DATABASE_URL" => "postgresql://unsafe-role@localhost:1/paid",
        "RUBYOPT" => "-r#{probe_path}"
      }

      stdout, stderr, status = Open3.capture3(
        environment, script_path, "--plan", "--project", "1", "--image", "sha256:approved", chdir: directory
      )

      expect(status).to be_success, -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("Preflight: ready")
      expect(stderr).to include("RAILS_BOOTED=false")
    end
  end

  it "rejects whitespace-only host configuration values" do
    environment = {
      "APPLE_VERIFICATION_HOST_URL" => " ",
      "APPLE_VERIFICATION_HOST_TOKEN" => " ",
      "APPLE_VERIFICATION_GUEST_EXECUTOR_TOKEN" => " "
    }

    stdout, _stderr, status = Open3.capture3(
      environment, script_path, "--plan", "--project", "1", "--image", "sha256:approved"
    )

    expect(status).to be_success
    expect(stdout).to include("APPLE_VERIFICATION_HOST_URL is not configured")
    expect(stdout).to include("APPLE_VERIFICATION_HOST_TOKEN is not configured")
    expect(stdout).to include("APPLE_VERIFICATION_GUEST_EXECUTOR_TOKEN is not configured")
    expect(stdout).not_to include("Preflight: ready")
  end

  def script_path
    Rails.root.join("bin/apple-verify-live").to_s
  end
end
