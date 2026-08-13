# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::Providers::Data::Review do
  it "is an immutable Data class with the documented fields" do
    review = described_class.new(
      id: 1, author_login: "alice", state: :approved, raw_state: "APPROVED",
      body: "lgtm", submitted_at: Time.at(0), commit_sha: "abc"
    )

    expect(review.state).to eq(:approved)
    expect(review.body).to eq("lgtm")
  end

  it "declares the provider-neutral state enum" do
    expect(described_class::STATES).to include(
      :approved, :changes_requested, :commented, :dismissed, :pending
    )
  end
end
