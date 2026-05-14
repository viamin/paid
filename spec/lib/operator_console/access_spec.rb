# frozen_string_literal: true

require "rails_helper"

RSpec.describe OperatorConsole::Access, :no_db do
  let(:user) do
    Struct.new(:id, :email).new(42, "operator@example.com")
  end

  around do |example|
    original_emails = ENV["PAID_OPERATOR_EMAILS"]
    original_ids = ENV["PAID_OPERATOR_USER_IDS"]
    described_class.reset_memoized!
    example.run
  ensure
    ENV["PAID_OPERATOR_EMAILS"] = original_emails
    ENV["PAID_OPERATOR_USER_IDS"] = original_ids
    described_class.reset_memoized!
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
end
