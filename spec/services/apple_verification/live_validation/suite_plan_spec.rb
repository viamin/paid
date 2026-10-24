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

  def script_path
    Rails.root.join("bin/apple-verify-live").to_s
  end
end
