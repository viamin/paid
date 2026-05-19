# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperatorConsole::Access, :no_db do
  let(:user) do
    Struct.new(:id, :email).new(42, "operator@example.com")
  end

  let(:credentials) { instance_double(Hash) }

  around do |example|
    original_emails = ENV["PAID_OPERATOR_EMAILS"]
    original_ids = ENV["PAID_OPERATOR_USER_IDS"]
    example.run
  ensure
    ENV["PAID_OPERATOR_EMAILS"] = original_emails
    ENV["PAID_OPERATOR_USER_IDS"] = original_ids
  end

  before do
    allow(Rails.application).to receive(:credentials).and_return(credentials)
    allow(credentials).to receive(:dig).with(:operator_console, :emails).and_return(nil)
    allow(credentials).to receive(:dig).with(:operator_console, :user_ids).and_return(nil)
  end

  it "fails closed when no allowlist is configured" do
    ENV.delete("PAID_OPERATOR_EMAILS")
    ENV.delete("PAID_OPERATOR_USER_IDS")

    expect(described_class.allowed?(user)).to be(false)
  end

  it "allows a configured email address" do
    ENV["PAID_OPERATOR_EMAILS"] = "operator@example.com"

    expect(described_class.allowed?(user)).to be(true)
  end

  it "allows a configured user id" do
    ENV["PAID_OPERATOR_USER_IDS"] = "42"

    expect(described_class.allowed?(user)).to be(true)
  end

  it "re-reads configuration after env changes without requiring a cache reset" do
    ENV["PAID_OPERATOR_EMAILS"] = "operator@example.com"
    expect(described_class.allowed?(user)).to be(true)

    ENV["PAID_OPERATOR_EMAILS"] = "different@example.com"
    expect(described_class.allowed?(user)).to be(false)
  end

  it "fails closed when an operator env var is explicitly blank" do
    ENV["PAID_OPERATOR_EMAILS"] = ""
    allow(credentials).to receive(:dig).with(:operator_console, :emails).and_return([ "operator@example.com" ])

    expect(described_class.allowed?(user)).to be(false)
  end

  it "falls back to credentials when env vars are absent" do
    ENV.delete("PAID_OPERATOR_EMAILS")
    allow(credentials).to receive(:dig).with(:operator_console, :emails).and_return([ "operator@example.com" ])

    expect(described_class.allowed?(user)).to be(true)
  end

  it "fails closed when encrypted credentials are unavailable" do
    ENV.delete("PAID_OPERATOR_EMAILS")
    allow(credentials).to receive(:dig)
      .with(:operator_console, :emails)
      .and_raise(
        ActiveSupport::EncryptedFile::MissingKeyError.new(
          key_path: Pathname.new("config/credentials/test.key"),
          env_key: "RAILS_TEST_KEY"
        )
      )

    expect(described_class.allowed?(user)).to be(false)
  end
end
