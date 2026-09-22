# frozen_string_literal: true

require "rails_helper"

# @spec APPLE-SETUP-001
# @spec APPLE-SETUP-002
RSpec.describe AppleVerification::Setup::Preflight do
  let(:shell) do
    AppleVerification::Setup::Shell.new(capture: ->(*argv) { fake_capture(*argv) })
  end

  let(:reconciliation_tags) do
    {
      "paid.account_id" => "1",
      "paid.project_id" => "2",
      "paid.run_id" => "7",
      "paid.created_at" => "2026-09-20T00:00:00Z",
      "paid.resource" => "apple_vm"
    }
  end

  let(:command_responses) { default_responses }
  let(:approved_image_digest) { "sha256:#{'a' * 64}" }
  let(:local_tart_vm_names) { [ "paid-macos-base" ] }
  let(:vm_dir_digests) { { "paid-macos-base" => approved_image_digest.delete_prefix("sha256:") } }

  def default_responses
    {
      [ "sysctl", "-n", "kern.hv_vmm_present" ] => [ "1", "", status(0) ],
      [ "which", "tart" ] => [ "/opt/homebrew/bin/tart", "", status(0) ],
      [ "tart", "--version" ] => [ "2.37.0", "", status(0) ],
      [ "tart", "softnet", "status" ] => [ "softnet running", "", status(0) ],
      [ "tart", "list" ] => [ "", "", status(0) ],
      [ "xcode-select", "-p" ] => [ "/Applications/Xcode.app/Contents/Developer", "", status(0) ],
      [ "xcodebuild", "-version" ] => [ "Xcode 26.6\nBuild version 17F113", "", status(0) ],
      [ "xcrun", "simctl", "list", "runtimes" ] => [ "iOS 17.0\nmacOS 14.0", "", status(0) ],
      [ "dscl", ".", "-list", "/Users" ] => [ "root\npaidguest\n", "", status(0) ],
      [ "df", "-g", "/" ] => [ "/dev/disk1s1  500G  200G  300  50%  /", "", status(0) ],
      [ "vm_stat" ] => [ "Pages free: 12345.\nPages active: 12000.\nPages inactive: 8000.\n", "", status(0) ]
    }
  end

  def fake_capture(*argv)
    key = argv.first(2) == %w[which] ? argv : argv
    command_responses.fetch(key) do
      [ "", "command not stubbed: #{argv.inspect}", status(127) ]
    end
  end

  def status(code)
    instance_double(Process::Status, success?: code.zero?, exitstatus: code, to_i: code)
  end

  def stub_host_service(readiness: nil)
    fake_host = Class.new do
      def initialize(readiness)
        @readiness = readiness
      end

      def call(version:, operation:, payload:, token:)
        raise "host service stub missing for #{operation.inspect}" unless operation == "readiness"

        @readiness || raise("host service readiness stub missing")
      end
    end.new(readiness)

    allow(AppleVerification::HostClient).to receive(:new).and_return(fake_host)
    fake_host
  end

  before do
    stub_host_service(
      readiness: {
        "cpu" => { "available_cores" => 4 },
        "memory" => { "free_percent" => 50 },
        "disk" => { "free_gib" => 200 },
        "network" => { "proxy_relay" => "paid-egress" }
      }
    )
    allow(shell).to receive_messages(
      tart_home_dir: "/tmp/paid-tart-home",
      local_tart_vm_names: local_tart_vm_names
    )
    allow(shell).to receive(:vm_dir_digest) do |name|
      vm_dir_digests.fetch(name.to_s, nil)
    end
  end

  describe "#call" do
    it "performs only read-only inspections and reports every check" do
      report = described_class.call(
        shell:,
        profile_id: "ios-standard",
        approved_image_digests: [ approved_image_digest ],
        host_url: "https://macos-worker.example/lifecycle",
        host_token: "host-token"
      )

      expect(report.results).to all(be_a(AppleVerification::Setup::Preflight::Result))
      expect(report.results.map(&:id)).to include(:virtualization_permission, :tart_binary, :softnet,
        :approved_image, :xcode_toolchain, :simulator_runtimes, :guest_gui_account,
        :host_service_authentication, :proxy_enforcement, :capacity)
    end

    it "records a gap and the exact fix-it command when virtualization permission is missing" do
      command_responses[[ "sysctl", "-n", "kern.hv_vmm_present" ]] = [ "0", "", status(0) ]

      report = described_class.call(
        shell:,
        approved_image_digests: [],
        host_url: "https://macos-worker.example/lifecycle",
        host_token: "host-token"
      )

      check = report.results.find { |result| result.id == :virtualization_permission }
      expect(check.status).to eq(:gap)
      expect(check.fix).to include("sysctl kern.hv_vmm_present")
      expect(report.gapped?).to be(true)
    end

    it "records a gap when tart is missing or reports an older major" do
      command_responses[[ "which", "tart" ]] = [ "", "not found", status(1) ]

      report = described_class.call(
        shell:,
        approved_image_digests: [],
        host_url: "https://macos-worker.example/lifecycle",
        host_token: "host-token"
      )

      check = report.results.find { |result| result.id == :tart_binary }
      expect(check.status).to eq(:gap)
      expect(check.fix).to include("brew install cirruslabs/cli/tart")
    end

    it "records a gap when Softnet is not running" do
      command_responses[[ "tart", "softnet", "status" ]] = [ "softnet stopped", "", status(0) ]

      report = described_class.call(
        shell:,
        approved_image_digests: [],
        host_url: "https://macos-worker.example/lifecycle",
        host_token: "host-token"
      )

      check = report.results.find { |result| result.id == :softnet }
      expect(check.status).to eq(:gap)
      expect(check.fix).to include("sudo tart softnet start")
    end

    it "records a gap when no approved image digest matches a local Tart image" do
      allow(shell).to receive(:vm_dir_digest).with("paid-macos-base").and_return("fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")

      report = described_class.call(
        shell:,
        approved_image_digests: [ approved_image_digest ],
        host_url: "https://macos-worker.example/lifecycle",
        host_token: "host-token"
      )

      check = report.results.find { |result| result.id == :approved_image }
      expect(check.status).to eq(:gap)
      expect(check.fix).to include("tart clone <source-image> paid-macos-base")
    end

    it "records a gap when there are no local Tart VM directories" do
      allow(shell).to receive(:local_tart_vm_names).and_return([])

      report = described_class.call(
        shell:,
        approved_image_digests: [ approved_image_digest ],
        host_url: "https://macos-worker.example/lifecycle",
        host_token: "host-token"
      )

      check = report.results.find { |result| result.id == :approved_image }
      expect(check.status).to eq(:gap)
      expect(check.detail).to include("/tmp/paid-tart-home/vms")
    end

    it "rejects digest matches that share only a prefix" do
      prefix = approved_image_digest[0, 16]
      allow(shell).to receive(:vm_dir_digest).with("paid-macos-base").and_return(prefix.delete_prefix("sha256:") + "deadbeef")

      report = described_class.call(
        shell:,
        approved_image_digests: [ approved_image_digest ],
        host_url: "https://macos-worker.example/lifecycle",
        host_token: "host-token"
      )

      check = report.results.find { |result| result.id == :approved_image }
      expect(check.status).to eq(:gap)
    end

    it "passes when the local VM directory digest matches an approved digest exactly" do
      report = described_class.call(
        shell:,
        approved_image_digests: [ approved_image_digest ],
        host_url: "https://macos-worker.example/lifecycle",
        host_token: "host-token"
      )

      check = report.results.find { |result| result.id == :approved_image }
      expect(check.status).to eq(:pass)
      expect(check.detail).to include("paid-macos-base")
      expect(check.detail).to include(approved_image_digest.delete_prefix("sha256:"))
    end

    it "compares approved and computed digests case-insensitively" do
      allow(shell).to receive(:vm_dir_digest).with("paid-macos-base")
        .and_return(approved_image_digest.delete_prefix("sha256:").upcase)

      report = described_class.call(
        shell:,
        approved_image_digests: [ approved_image_digest.downcase ],
        host_url: "https://macos-worker.example/lifecycle",
        host_token: "host-token"
      )

      check = report.results.find { |result| result.id == :approved_image }
      expect(check.status).to eq(:pass)
    end

    it "records a gap when Xcode license is not accepted" do
      command_responses[[ "xcodebuild", "-version" ]] = [ "", "license not accepted", status(69) ]

      report = described_class.call(
        shell:,
        approved_image_digests: [],
        host_url: "https://macos-worker.example/lifecycle",
        host_token: "host-token"
      )

      check = report.results.find { |result| result.id == :xcode_toolchain }
      expect(check.status).to eq(:gap)
      expect(check.fix).to include("sudo xcodebuild -license accept")
    end

    it "records a gap when no Simulator runtimes are installed" do
      command_responses[[ "xcrun", "simctl", "list", "runtimes" ]] = [ "no runtimes installed", "", status(0) ]

      report = described_class.call(
        shell:,
        approved_image_digests: [],
        host_url: "https://macos-worker.example/lifecycle",
        host_token: "host-token"
      )

      check = report.results.find { |result| result.id == :simulator_runtimes }
      expect(check.status).to eq(:gap)
      expect(check.fix).to include("xcodebuild -downloadPlatform iOS")
    end

    it "records a gap when no dedicated guest GUI account exists" do
      command_responses[[ "dscl", ".", "-list", "/Users" ]] = [ "root\noperator\n", "", status(0) ]

      report = described_class.call(
        shell:,
        approved_image_digests: [],
        host_url: "https://macos-worker.example/lifecycle",
        host_token: "host-token"
      )

      check = report.results.find { |result| result.id == :guest_gui_account }
      expect(check.status).to eq(:gap)
      expect(check.fix).to include("paidguest")
      expect(check.fix).not_to include("apple id", "Apple ID")
    end

    it "records a gap when host service auth env vars are unset" do
      report = described_class.call(
        shell:,
        approved_image_digests: [],
        host_url: "",
        host_token: ""
      )

      check = report.results.find { |result| result.id == :host_service_authentication }
      expect(check.status).to eq(:gap)
      expect(check.fix).to include("APPLE_VERIFICATION_HOST_URL")
      expect(check.fix).to include("APPLE_VERIFICATION_HOST_TOKEN")
    end

    it "records a gap when host service authentication is rejected" do
      allow(AppleVerification::HostClient).to receive(:new).and_return(
        Class.new do
          def call(**) raise AppleVerification::HostService::AuthenticationError, "unauthenticated" end
        end.new
      )

      report = described_class.call(
        shell:,
        approved_image_digests: [],
        host_url: "https://macos-worker.example/lifecycle",
        host_token: "host-token"
      )

      check = report.results.find { |result| result.id == :host_service_authentication }
      expect(check.status).to eq(:gap)
      expect(check.fix).to include("rotate-token")
    end

    it "records a gap when the host service does not declare the Paid-controlled proxy relay" do
      stub_host_service(
        readiness: {
          "cpu" => { "available_cores" => 4 },
          "memory" => { "free_percent" => 50 },
          "disk" => { "free_gib" => 200 },
          "network" => {}
        }
      )

      report = described_class.call(
        shell:,
        approved_image_digests: [],
        host_url: "https://macos-worker.example/lifecycle",
        host_token: "host-token"
      )

      check = report.results.find { |result| result.id == :proxy_enforcement }
      expect(check.status).to eq(:gap)
      expect(check.fix).to include("paid-egress")
    end

    it "rejects proxy_relay values that merely substring-match paid-egress" do
      stub_host_service(
        readiness: {
          "cpu" => { "available_cores" => 4 },
          "memory" => { "free_percent" => 50 },
          "disk" => { "free_gib" => 200 },
          "network" => { "proxy_relay" => "malicious-paid-egress-relay" }
        }
      )

      report = described_class.call(
        shell:,
        approved_image_digests: [],
        host_url: "https://macos-worker.example/lifecycle",
        host_token: "host-token"
      )

      check = report.results.find { |result| result.id == :proxy_enforcement }
      expect(check.status).to eq(:gap)
    end

    it "records a gap when free host disk is below the operator minimum" do
      command_responses[[ "df", "-g", "/" ]] = [ "/dev/disk1s1  500G  450G  50  90%  /", "", status(0) ]

      report = described_class.call(
        shell:,
        approved_image_digests: [],
        host_url: "https://macos-worker.example/lifecycle",
        host_token: "host-token"
      )

      check = report.results.find { |result| result.id == :capacity }
      expect(check.status).to eq(:gap)
      expect(check.fix).to include("60 GiB")
    end

    it "parses df -g output with unit-less Available values (the modern macOS shape)" do
      command_responses[[ "df", "-g", "/" ]] = [ "/dev/disk1s1  500G  200G  300  50%  /", "", status(0) ]

      report = described_class.call(
        shell:,
        approved_image_digests: [],
        host_url: "https://macos-worker.example/lifecycle",
        host_token: "host-token"
      )

      check = report.results.find { |result| result.id == :capacity }
      expect(check.status).to eq(:pass)
      expect(check.detail).to include("300 GiB")
    end

    it "marks the report ready when every check passes" do
      report = described_class.call(
        shell:,
        approved_image_digests: [ approved_image_digest ],
        host_url: "https://macos-worker.example/lifecycle",
        host_token: "host-token"
      )

      expect(report.status).to eq(:ready)
      expect(report.ready?).to be(true)
    end
  end
end
