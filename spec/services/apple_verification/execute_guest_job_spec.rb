# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerification::ExecuteGuestJob do # @spec APPLE-VERIFY-005
  let(:project) { create(:project) }
  let(:adapters) { { "build" => ->(payload) { { "scheme" => payload.fetch("scheme") } } } }
  let(:manifest) { { "version" => 1, "operations" => [ { "type" => "build", "payload" => { "scheme" => "App" } } ] } }

  around do |example|
    FeatureFlags.enable!(:apple_verification_workers, project: project)
    example.run
  ensure
    FeatureFlags.disable!(:apple_verification_workers, project: project)
  end

  it "selects the requested active image and dispatches the validated manifest" do
    image = create(:apple_verification_image, :active, account: project.account)

    result = described_class.call(project:, manifest:, adapters:, image_digest: image.digest)

    expect(result.image).to eq(image)
    expect(result.operations).to eq([ { "scheme" => "App" } ])
  end

  it "does not dispatch when the rollout is disabled" do
    FeatureFlags.disable!(:apple_verification_workers, project: project)

    expect { described_class.call(project:, manifest:, adapters:, image_digest: "sha256:#{'0' * 64}") }
      .to raise_error(described_class::FeatureDisabledError)
  end

  it "does not dispatch when the account has no matching active image" do
    image = create(:apple_verification_image, account: project.account)

    expect { described_class.call(project:, manifest:, adapters:, image_digest: image.digest) }
      .to raise_error(described_class::NoActiveImageError)
  end

  it "does not dispatch an invalid manifest" do
    image = create(:apple_verification_image, :active, account: project.account)

    expect { described_class.call(project:, manifest: manifest.merge("version" => 2), adapters:, image_digest: image.digest) }
      .to raise_error(AppleVerification::GuestProtocol::UnsupportedVersionError)
  end

  it "selects the requested digest when the account has multiple active images" do
    requested_image = create(:apple_verification_image, :active, account: project.account, name: "ios-app")
    create(:apple_verification_image, :active, account: project.account, name: "mac-app")

    result = described_class.call(project:, manifest:, adapters:, image_digest: requested_image.digest)

    expect(result.image).to eq(requested_image)
  end
end
