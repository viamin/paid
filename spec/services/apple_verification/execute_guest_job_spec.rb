# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerification::ExecuteGuestJob do # @spec APPLE-VERIFY-005
  let(:project) { create(:project) }
  let(:manifest) { { "version" => 1, "operations" => [ { "type" => "build", "payload" => { "scheme" => "App" } } ] } }
  let(:guest_connection) { instance_spy(AppleVerification::GuestConnection) }

  around do |example|
    FeatureFlags.enable!(:apple_verification_workers, project: project)
    example.run
  ensure
    FeatureFlags.disable!(:apple_verification_workers, project: project)
  end

  it "dispatches the validated manifest to the selected image's guest connection" do
    image = create(:apple_verification_image, :active, account: project.account)
    allow(guest_connection).to receive(:dispatch!).with(image:, manifest:).and_return([ { "scheme" => "App" } ])

    result = described_class.call(project:, manifest:, guest_connection:, image_digest: image.digest)

    expect(result.image).to eq(image)
    expect(result.operations).to eq([ { "scheme" => "App" } ])
  end

  it "does not dispatch when the rollout is disabled" do
    FeatureFlags.disable!(:apple_verification_workers, project: project)

    expect { described_class.call(project:, manifest:, guest_connection:, image_digest: "sha256:#{'0' * 64}") }
      .to raise_error(described_class::FeatureDisabledError)
    expect(guest_connection).not_to have_received(:dispatch!)
  end

  it "does not dispatch when the account has no matching active image" do
    image = create(:apple_verification_image, account: project.account)

    expect { described_class.call(project:, manifest:, guest_connection:, image_digest: image.digest) }
      .to raise_error(described_class::NoActiveImageError)
    expect(guest_connection).not_to have_received(:dispatch!)
  end

  it "does not dispatch an invalid manifest" do
    image = create(:apple_verification_image, :active, account: project.account)

    expect { described_class.call(project:, manifest: manifest.merge("version" => 2), guest_connection:, image_digest: image.digest) }
      .to raise_error(AppleVerification::GuestProtocol::UnsupportedVersionError)
    expect(guest_connection).not_to have_received(:dispatch!)
  end

  it "selects the requested digest when the account has multiple active images" do
    requested_image = create(:apple_verification_image, :active, account: project.account, name: "ios-app")
    create(:apple_verification_image, :active, account: project.account, name: "mac-app")

    allow(guest_connection).to receive(:dispatch!).with(image: requested_image, manifest:).and_return([])

    result = described_class.call(project:, manifest:, guest_connection:, image_digest: requested_image.digest)

    expect(result.image).to eq(requested_image)
  end
end
