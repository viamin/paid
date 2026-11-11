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
end
