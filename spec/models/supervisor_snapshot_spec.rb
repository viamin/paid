# frozen_string_literal: true

require "rails_helper"

RSpec.describe SupervisorSnapshot do
  describe "sanitized persistence" do
    it "accepts typed operational facts and bounds the retained digest" do # @spec OPERATIONAL-SUPERVISOR-001, OPERATIONAL-SUPERVISOR-002, OPERATIONAL-SUPERVISOR-003
      snapshot = build(:supervisor_snapshot)

      expect(snapshot).to be_valid
    end

    it "rejects authored content and secrets from its durable payloads" do # @spec OPERATIONAL-SUPERVISOR-001
      snapshot = build(:supervisor_snapshot, digest: { "issue_body" => "customer text", "token" => "secret" })

      expect(snapshot).to be_invalid
      expect(snapshot.errors[:digest]).to include("contains unsupported or unsafe fields")
    end
  end

  describe ".expired" do
    it "finds only records whose recorded retention interval elapsed" do # @spec OPERATIONAL-SUPERVISOR-003
      expired = create(:supervisor_snapshot, captured_at: 2.days.ago, retention_expires_at: 1.second.ago)
      create(:supervisor_snapshot, retention_expires_at: 1.second.from_now)

      expect(described_class.expired).to contain_exactly(expired)
    end
  end
end
