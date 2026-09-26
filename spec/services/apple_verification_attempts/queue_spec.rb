# frozen_string_literal: true

require "rails_helper"

RSpec.describe AppleVerificationAttempts::Queue do
  # @spec APPLE-ATTEMPT-003
  it "returns each account head before a second attempt from the same account" do
    first = create(:apple_verification_attempt)
    second = create(:apple_verification_attempt, account: first.account, project: first.project)
    other = create(:apple_verification_attempt)

    queue = described_class.new

    expect(queue.next).to eq(first)
    expect(queue.position(other)).to eq(2)
    expect(queue.position(second)).to eq(3)
  end

  it "cancels a queued attempt idempotently" do
    attempt = create(:apple_verification_attempt)

    expect { described_class.new.cancel(attempt) }.to change { attempt.reload.status }.from("queued").to("cancelled")
    expect { described_class.new.cancel(attempt) }.not_to change { attempt.reload.status }
  end
end
