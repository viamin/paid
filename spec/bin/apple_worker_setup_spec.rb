# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "open3"
require "tmpdir"

# @spec APPLE-SETUP-007
RSpec.describe "bin/apple-worker-setup" do # rubocop:disable RSpec/DescribeClass
  let(:script_path) { File.expand_path("../../bin/apple-worker-setup", __dir__) }
  let(:readiness_response) do
    {
      "cpu" => { "available_cores" => 4 },
      "memory" => { "free_percent" => 50 },
      "disk" => { "free_gib" => 200 },
      "network" => { "proxy_relay" => "paid-egress" }
    }
  end

  describe "CLI parsing and exit codes" do
    it "prints the usage banner and exits 0 on --help" do
      stdout, stderr, status = run_setup("--help")
      expect(status.exitstatus).to eq(0), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stderr).to include("RAILS_BOOTED=false")
      expect([ stdout, stderr ].join("\n")).to include("Usage:")
      expect([ stdout, stderr ].join("\n")).to include("--preflight")
      expect([ stdout, stderr ].join("\n")).to include("--smoke")
    end

    it "exits 2 when --smoke is used without --project or --image" do
      _stdout, stderr, status = run_setup("--smoke", env: { "APPLE_VERIFICATION_HOST_URL" => "https://macos-worker.example.test/lifecycle", "APPLE_VERIFICATION_HOST_TOKEN" => "host-token" })
      expect(status.exitstatus).to eq(2), -> { "stderr: #{stderr}" }
      expect(stderr).to include("RAILS_BOOTED=false")
      expect(stderr).to include("--project and --image")
    end

    it "exits 2 with usage when --smoke is missing APPLE_VERIFICATION_HOST_URL or HOST_TOKEN" do
      _stdout, stderr, status = run_setup("--smoke", "--project", "1", "--image", "sha256:abc")
      expect(status.exitstatus).to eq(2), -> { "stderr: #{stderr}" }
      expect(stderr).to include("RAILS_BOOTED=false")
      expect(stderr).to include("--smoke requires APPLE_VERIFICATION_HOST_URL")
      expect(stderr).to include("Usage:")
    end

    # @spec TEST-SUITE-008
    it "uses Rails database settings when DATABASE_URL is absent" do
      stdout, stderr, status = run_setup("--preflight", env: { "DATABASE_URL" => nil })
      expect([ 0, 1 ]).to include(status.exitstatus), -> { "stdout: #{stdout}\nstderr: #{stderr}" }
      expect(stdout).to include("# Apple worker setup report")
    end

    it "exits 0 or 1 in preflight mode and prints a Markdown report" do
      stdout, _stderr, status = run_setup("--preflight")
      # Preflight on a non-macOS test host will surface gaps (no Tart,
      # no Xcode, no host service), so exit 1 is expected; the test only
      # asserts that the driver runs to completion and prints Markdown.
      expect([ 0, 1 ]).to include(status.exitstatus), -> { stdout }
      expect(stdout).to include("# Apple worker setup report")
      expect(stdout).to include("## Preflight")
    end
  end

  def run_setup(*args, env: {})
    base_env = {
      "BUNDLE_GEMFILE" => File.expand_path("../../Gemfile", __dir__),
      # @spec TEST-SUITE-008
      # Open3 inherits DB_* settings; a URL is optional in Rails config.
      "PAID_SKIP_DATABASE_RUNTIME_ROLE_GUARD" => "true",
      "APPLE_VERIFICATION_HOST_URL" => "",
      "APPLE_VERIFICATION_HOST_TOKEN" => ""
    }

    Dir.mktmpdir("apple-worker-setup-spec") do |dir|
      # @spec TEST-SUITE-010
      probe = File.join(dir, "boot_probe.rb")
      File.write(probe, 'at_exit { warn "RAILS_BOOTED=#{defined?(Rails::Application) ? true : false}" }')
      base_env["RUBYOPT"] = [ ENV["RUBYOPT"], "-r#{probe}" ].compact.join(" ")
      base_env["HOME"] = dir
      Open3.capture3(base_env.merge(env), script_path, *args, chdir: dir)
    end
  end
end
