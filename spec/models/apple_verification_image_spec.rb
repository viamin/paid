# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationImage, type: :model do # @spec APPLE-VERIFY-001, APPLE-VERIFY-002
  subject(:image) { build(:apple_verification_image) }

  it "records the immutable toolchain, capacity, network, GUI, and smoke-test facts" do
    expect(image).to be_valid
    expect(image.toolchain).to include("macos_version" => "26.6.2", "xcode_version" => "26.6")
    expect(image.resources).to include("cpu_count" => 4, "memory_gib" => 8, "disk_gib" => 100)
    expect(image.gui_account).to include("admin" => false, "apple_id" => false, "persistent_secret_keychain" => false)
  end

  it "requires every dedicated guest-account isolation assertion" do
    image.gui_account["persistent_secret_keychain"] = true

    expect(image).not_to be_valid
    expect(image.errors[:gui_account]).to include("must declare a non-admin account without Apple ID, personal data, host credentials, or a persistent secret-bearing keychain")
  end

  it "keeps image identity and recorded capability facts immutable" do
    image = create(:apple_verification_image)
    image.toolchain["xcode_version"] = "27.0"

    expect(image).not_to be_valid
    expect(image.errors[:base]).to include("Apple verification image facts are immutable after publication")
  end

  it "promotes only smoke-tested candidates and exposes only active images as schedulable" do
    image = create(:apple_verification_image, smoke_test: { "passed" => true })

    expect { image.promote! }.to change { image.reload.status }.from("candidate").to("active")
    expect(image).to be_schedulable
    expect(described_class.schedulable).to contain_exactly(image)
  end

  it "refuses to promote an image with a failed smoke test" do
    image = create(:apple_verification_image, smoke_test: { "passed" => false })

    expect { image.promote! }.to raise_error(AppleVerificationImage::SmokeTestRequiredError)
  end

  it "records deprecation, retirement, and immediate revocation without making an inactive image schedulable" do
    image = create(:apple_verification_image, :active)

    image.deprecate!(reason: "Xcode successor", retirement_at: 2.weeks.from_now)
    expect(image).to be_deprecated
    expect(image.retirement_at).to be_present

    image.retire!(reason: "migration complete")
    expect(image).to be_retired
    expect(image).not_to be_schedulable

    revoked = create(:apple_verification_image, :active)
    revoked.revoke!(reason: "security incident")
    expect(revoked).to be_revoked
    expect(revoked).not_to be_schedulable
  end
end
