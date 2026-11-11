# frozen_string_literal: true

require "rails_helper"

RSpec.describe Screenshots::SeedData::PaidJourney do
  # @spec LIVE-PREVIEW-012
  it "creates and removes only the isolated journey identity and project" do
    described_class.call

    account = Account.find_by!(slug: described_class::ACCOUNT_SLUG)
    expect(account.seed_owner).to eq(described_class::SEED_OWNER)
    expect(account.users.find_by!(email: described_class::USER_EMAIL)).to be_present
    expect(account.projects.find_by!(name: described_class::PROJECT_NAME)).to be_present

    described_class.cleanup!

    expect(Account.find_by(slug: described_class::ACCOUNT_SLUG)).to be_nil
  end

  # @spec LIVE-PREVIEW-012
  it "reuses the marked account from a previous journey run" do
    described_class.call
    account = Account.find_by!(slug: described_class::ACCOUNT_SLUG)

    described_class.call

    expect(Account.find_by!(slug: described_class::ACCOUNT_SLUG)).to eq(account)
  end

  # @spec LIVE-PREVIEW-012
  it "keeps concurrent setup on the fixed journey identity" do
    errors = Queue.new
    ready = Queue.new
    start = Queue.new
    threads = 4.times.map do
      Thread.new do
        ready << true
        start.pop
        described_class.call
      rescue StandardError => error
        errors << error
      end
    end

    4.times { ready.pop }
    4.times { start << true }
    threads.each(&:join)

    expect(errors).to be_empty
    expect(Account.where(seed_owner: described_class::SEED_OWNER).pluck(:slug)).to eq([ described_class::ACCOUNT_SLUG ])
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

  # @spec LIVE-PREVIEW-012
  it "refuses to adopt or destroy an unmarked account colliding on slug and email" do
    existing_account = create(:account, slug: described_class::ACCOUNT_SLUG)
    create(:user, account: existing_account, email: described_class::USER_EMAIL)

    expect { described_class.call }.to raise_error(
      described_class::AccountCollision,
      /is not a journey account/
    )

    described_class.cleanup!

    expect(existing_account.reload).to be_present
    expect(existing_account.projects).to be_empty
    expect(existing_account.users.exists?(email: described_class::USER_EMAIL)).to be(true)
  end
end
