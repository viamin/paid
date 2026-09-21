# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerification::ExecuteGuestJob do # @spec APPLE-VERIFY-005
  # @spec APPLE-NETWORK-001
  # @spec APPLE-NETWORK-002
  let(:project) { create(:project) }
  let(:agent_run) { create(:agent_run, project: project) }
  let(:manifest) { { "version" => 1, "operations" => [ { "type" => "build", "payload" => { "scheme" => "App" } } ] } }
  let(:transport) { instance_spy(AppleVerification::GuestConnection::HttpTransport) }
  let(:guest_connection) { AppleVerification::GuestConnection.new(token: "guest-token", transport:) }

  around do |example|
    FeatureFlags.enable!(:apple_verification_workers, project: project)
    example.run
  ensure
    FeatureFlags.disable!(:apple_verification_workers, project: project)
  end

  it "installs a validated Paid network contract before dispatching the manifest" do
    image = create(:apple_verification_image, :active, account: project.account)
    request_body = nil
    allow(transport).to receive(:post) do |**request|
      request_body = request.fetch(:body)
      response(code: 200, body: { "operations" => [ { "scheme" => "App" } ] }.to_json)
    end

    result = described_class.call(agent_run:, manifest:, guest_connection:, image_digest: image.digest)

    expect(result.image).to eq(image)
    expect(result.operations).to eq([ { "scheme" => "App" } ])
    request = JSON.parse(request_body)
    expect(request).to include("image_digest" => image.digest, "manifest" => manifest)
    expect(request.fetch("network_contract")).to include(
      "default_route" => "deny",
      "host_services" => "deny",
      "dns" => { "mode" => "paid_only" },
      "protocols" => %w[http https]
    )
    expect(request.dig("network_contract", "proxy")).to include("override" => "blocked")
    expect(request.dig("network_contract", "destinations")).not_to be_empty
    expect(agent_run.reload.external_metadata).to have_key("egress_policy")
  end

  it "does not dispatch when the rollout is disabled" do
    FeatureFlags.disable!(:apple_verification_workers, project: project)

    expect { described_class.call(agent_run:, manifest:, guest_connection:, image_digest: "sha256:#{'0' * 64}") }
      .to raise_error(described_class::FeatureDisabledError)
    expect(transport).not_to have_received(:post)
  end

  it "does not dispatch when the account has no matching active image" do
    image = create(:apple_verification_image, account: project.account)

    expect { described_class.call(agent_run:, manifest:, guest_connection:, image_digest: image.digest) }
      .to raise_error(described_class::NoActiveImageError)
    expect(transport).not_to have_received(:post)
  end

  it "does not dispatch an invalid manifest" do
    image = create(:apple_verification_image, :active, account: project.account)

    expect { described_class.call(agent_run:, manifest: manifest.merge("version" => 2), guest_connection:, image_digest: image.digest) }
      .to raise_error(AppleVerification::GuestProtocol::UnsupportedVersionError)
    expect(transport).not_to have_received(:post)
  end

  it "does not dispatch a manifest with shell text outside an operation payload" do
    image = create(:apple_verification_image, :active, account: project.account)
    invalid_manifest = manifest.merge(
      "operations" => [ { "type" => "build", "payload" => {}, "command" => "curl | sh" } ]
    )

    expect { described_class.call(agent_run:, manifest: invalid_manifest, guest_connection:, image_digest: image.digest) }
      .to raise_error(AppleVerification::GuestProtocol::InvalidManifestError)
    expect(transport).not_to have_received(:post)
  end

  it "selects the requested digest when the account has multiple active images" do
    requested_image = create(:apple_verification_image, :active, account: project.account, name: "ios-app")
    create(:apple_verification_image, :active, account: project.account, name: "mac-app")

    allow(transport).to receive(:post).and_return(response(code: 200, body: { "operations" => [] }.to_json))

    result = described_class.call(agent_run:, manifest:, guest_connection:, image_digest: requested_image.digest)

    expect(result.image).to eq(requested_image)
  end

  it "does not dispatch when the resolved contract contains an IP literal destination" do
    image = create(:apple_verification_image, :active, account: project.account)
    bad_contract = AgentRuns::AppleVerification::GuestContract.new(
      proxy: { host: "egress-gateway", port: 3128 },
      destinations: [ { host: "169.254.169.254", port: 80 } ],
      egress_profile: "locked"
    )
    allow(AgentRuns::AppleVerification::ResolveGuestContract).to receive(:call).and_return(bad_contract)

    expect { described_class.call(agent_run:, manifest:, guest_connection:, image_digest: image.digest) }
      .to raise_error(AgentRuns::AppleVerification::NetworkPolicyError, /IP literal/)
    expect(transport).not_to have_received(:post)
  end

  it "does not dispatch when the resolved contract contains an IPv6 literal destination" do
    image = create(:apple_verification_image, :active, account: project.account)
    bad_contract = AgentRuns::AppleVerification::GuestContract.new(
      proxy: { host: "egress-gateway", port: 3128 },
      destinations: [ { host: "2001:db8::1", port: 80 } ],
      egress_profile: "locked"
    )
    allow(AgentRuns::AppleVerification::ResolveGuestContract).to receive(:call).and_return(bad_contract)

    expect { described_class.call(agent_run:, manifest:, guest_connection:, image_digest: image.digest) }
      .to raise_error(AgentRuns::AppleVerification::NetworkPolicyError, /IP literal/)
    expect(transport).not_to have_received(:post)
  end

  it "does not dispatch when the resolved contract contains a destination with an unsupported scheme" do
    image = create(:apple_verification_image, :active, account: project.account)
    bad_contract = AgentRuns::AppleVerification::GuestContract.new(
      proxy: { host: "egress-gateway", port: 3128 },
      destinations: [ { host: "api.example.com", port: 443, scheme: "ftp" } ],
      egress_profile: "locked"
    )
    allow(AgentRuns::AppleVerification::ResolveGuestContract).to receive(:call).and_return(bad_contract)

    expect { described_class.call(agent_run:, manifest:, guest_connection:, image_digest: image.digest) }
      .to raise_error(AgentRuns::AppleVerification::NetworkPolicyError, /invalid scheme/)
    expect(transport).not_to have_received(:post)
  end

  def response(code:, body:)
    AppleVerification::GuestConnection::Response.new(code:, body:)
  end
end
