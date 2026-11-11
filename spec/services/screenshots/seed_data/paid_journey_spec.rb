# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::SeedData::PaidJourney do
  # @spec LIVE-PREVIEW-012
  it "creates and removes only the isolated journey identity and project" do
    described_class.call

    account = Account.find_by!(slug: described_class::ACCOUNT_SLUG)
    expect(account.users.find_by!(email: described_class::USER_EMAIL)).to be_present
    expect(account.projects.find_by!(name: described_class::PROJECT_NAME)).to be_present

    described_class.cleanup!

    expect(Account.find_by(slug: described_class::ACCOUNT_SLUG)).to be_nil
  end

  # @spec LIVE-PREVIEW-012
  it "refuses to reuse a journey email owned by another account" do
    existing_user = create(
      :user,
      email: described_class::USER_EMAIL,
      password: "existing-password",
      password_confirmation: "existing-password"
    )

    expect { described_class.call }.to raise_error(
      described_class::IdentityCollision,
      /belongs to another account/
    )

    expect(Account.find_by(slug: described_class::ACCOUNT_SLUG)).to be_nil
    expect(existing_user.reload).to have_attributes(email: described_class::USER_EMAIL)
    expect(existing_user.valid_password?("existing-password")).to be(true)

    described_class.cleanup!

    expect(existing_user.reload).to be_present
  end

  # @spec LIVE-PREVIEW-012
  it "refuses to remove an existing account using the journey slug" do
    existing_account = create(:account, slug: described_class::ACCOUNT_SLUG)

    expect { described_class.call }.to raise_error(
      described_class::AccountCollision,
      /is not a journey account/
    )

    described_class.cleanup!

    expect(existing_account.reload).to be_present
  end
end
