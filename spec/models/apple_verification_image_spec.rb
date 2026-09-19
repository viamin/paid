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

  it "enforces promotion requirements for direct status updates" do
    image = create(:apple_verification_image, smoke_test: { "passed" => false })

    expect(image.update(status: "active")).to be(false)
    expect(image.errors[:smoke_test]).to include("must have passed before promotion")
    expect(image.errors[:promoted_at]).to include("is required when active")
    expect(image.reload).not_to be_schedulable
  end

  it "enforces deprecation and revocation audit timestamps for direct status updates" do
    deprecated_image = create(:apple_verification_image, :active)
    expect(deprecated_image.update(status: "deprecated", deprecation_reason: "Xcode successor", retirement_at: 2.weeks.from_now)).to be(false)
    expect(deprecated_image.errors[:deprecated_at]).to include("is required when deprecated")

    revoked_image = create(:apple_verification_image, :active)
    expect(revoked_image.update(status: "revoked", revocation_reason: "security incident")).to be(false)
    expect(revoked_image.errors[:revoked_at]).to include("is required when revoked")
  end

  it "allows only the documented lifecycle transitions" do
    image = create(:apple_verification_image)

    expect(image.update(status: "deprecated")).to be(false)
    expect(image.errors[:status]).to include("cannot transition from candidate to deprecated")
  end

  it "makes lifecycle operations idempotent" do
    image = create(:apple_verification_image, smoke_test: { "passed" => true })

    image.promote!
    promoted_at = image.promoted_at
    expect(image.promote!).to equal(image)
    expect(image.reload.promoted_at).to eq(promoted_at)

    image.deprecate!(reason: "Xcode successor", retirement_at: 2.weeks.from_now)
    deprecated_at = image.deprecated_at
    expect(image.deprecate!(reason: "ignored retry", retirement_at: 3.weeks.from_now)).to equal(image)
    expect(image.reload.deprecated_at).to eq(deprecated_at)

    travel_to(3.weeks.from_now) do
      image.retire!(reason: "migration complete")
      retired_at = image.retirement_at
      expect(image.retire!(reason: "ignored retry")).to equal(image)
      expect(image.reload.retirement_at).to eq(retired_at)
    end
  end

  it "refuses to retire before the scheduled retirement time and preserves the scheduled deadline" do
    image = create(:apple_verification_image, :active)
    retirement_at = 2.weeks.from_now
    image.deprecate!(reason: "Xcode successor", retirement_at: retirement_at)

    expect { image.retire!(reason: "too early") }.to raise_error(ArgumentError, "retirement time has not arrived")
    expect(image.reload.retirement_at).to be_within(1.second).of(retirement_at)
    expect(image).to be_deprecated
  end

  it "tracks lifecycle changes with Logidze" do
    image = create(:apple_verification_image, smoke_test: { "passed" => true })

    image.promote!

    expect(image.reload.log_data.versions.size).to be >= 2
  end

  it "records deprecation, retirement, and immediate revocation without making an inactive image schedulable" do
    image = create(:apple_verification_image, :active)

    retirement_at = 2.weeks.from_now
    image.deprecate!(reason: "Xcode successor", retirement_at: retirement_at)
    expect(image).to be_deprecated
    expect(image.retirement_at).to be_present

    travel_to(retirement_at + 1.second) { image.retire!(reason: "migration complete") }
    expect(image).to be_retired
    expect(image).not_to be_schedulable

    revoked = create(:apple_verification_image, :active)
    revoked.revoke!(reason: "security incident")
    expect(revoked).to be_revoked
    expect(revoked).not_to be_schedulable
  end
end
