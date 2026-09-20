# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerification::ExecuteGuestJob do # @spec APPLE-VERIFY-005
  let(:project) { create(:project) }
  let(:manifest) { { "version" => 1, "operations" => [ { "type" => "build", "payload" => { "scheme" => "App" } } ] } }
  let(:transport) { instance_spy(AppleVerification::GuestConnection::HttpTransport) }
  let(:guest_connection) { AppleVerification::GuestConnection.new(token: "guest-token", transport:) }

  around do |example|
    FeatureFlags.enable!(:apple_verification_workers, project: project)
    example.run
  ensure
    FeatureFlags.disable!(:apple_verification_workers, project: project)
  end

  it "dispatches the validated manifest to the selected image's authenticated guest executor" do
    image = create(:apple_verification_image, :active, account: project.account)
    allow(transport).to receive(:post).and_return(response(code: 200, body: { "operations" => [ { "scheme" => "App" } ] }.to_json))

    result = described_class.call(project:, manifest:, guest_connection:, image_digest: image.digest)

    expect(result.image).to eq(image)
    expect(result.operations).to eq([ { "scheme" => "App" } ])
    expect(transport).to have_received(:post).with(
      uri: URI("https://apple-executor.example.test/v1/jobs"),
      headers: { "Authorization" => "Bearer guest-token", "Content-Type" => "application/json" },
      body: { "image_digest" => image.digest, "manifest" => manifest }.to_json
    )
  end

  it "does not dispatch when the rollout is disabled" do
    FeatureFlags.disable!(:apple_verification_workers, project: project)

    expect { described_class.call(project:, manifest:, guest_connection:, image_digest: "sha256:#{'0' * 64}") }
      .to raise_error(described_class::FeatureDisabledError)
    expect(transport).not_to have_received(:post)
  end

  it "does not dispatch when the account has no matching active image" do
    image = create(:apple_verification_image, account: project.account)

    expect { described_class.call(project:, manifest:, guest_connection:, image_digest: image.digest) }
      .to raise_error(described_class::NoActiveImageError)
    expect(transport).not_to have_received(:post)
  end

  it "does not dispatch an invalid manifest" do
    image = create(:apple_verification_image, :active, account: project.account)

    expect { described_class.call(project:, manifest: manifest.merge("version" => 2), guest_connection:, image_digest: image.digest) }
      .to raise_error(AppleVerification::GuestProtocol::UnsupportedVersionError)
    expect(transport).not_to have_received(:post)
  end

  it "does not dispatch a manifest with shell text outside an operation payload" do
    image = create(:apple_verification_image, :active, account: project.account)
    invalid_manifest = manifest.merge(
      "operations" => [ { "type" => "build", "payload" => {}, "command" => "curl | sh" } ]
    )

    expect { described_class.call(project:, manifest: invalid_manifest, guest_connection:, image_digest: image.digest) }
      .to raise_error(AppleVerification::GuestProtocol::InvalidManifestError)
    expect(transport).not_to have_received(:post)
  end

  it "selects the requested digest when the account has multiple active images" do
    requested_image = create(:apple_verification_image, :active, account: project.account, name: "ios-app")
    create(:apple_verification_image, :active, account: project.account, name: "mac-app")

    allow(transport).to receive(:post).and_return(response(code: 200, body: { "operations" => [] }.to_json))

    result = described_class.call(project:, manifest:, guest_connection:, image_digest: requested_image.digest)

    expect(result.image).to eq(requested_image)
  end

  def response(code:, body:)
    AppleVerification::GuestConnection::Response.new(code:, body:)
  end
end
