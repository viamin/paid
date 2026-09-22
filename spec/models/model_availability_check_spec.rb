# frozen_string_literal: true

require "rails_helper"

# @spec MODEL-AVAILABILITY-001
RSpec.describe ModelAvailabilityCheck do
  describe "validations" do
    it { is_expected.to validate_presence_of(:runner_key) }
    it { is_expected.to validate_presence_of(:auth_type) }
    it { is_expected.to validate_presence_of(:source) }
    it { is_expected.to validate_presence_of(:checked_at) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
  end

  describe "associations" do
    it { is_expected.to belong_to(:llm_model) }
    it { is_expected.to belong_to(:account).optional }
  end

  describe "#available?" do
    it "is true only when status is available" do
      available = build(:model_availability_check, status: "available")
      unavailable = build(:model_availability_check, status: "unavailable")

      expect(available.available?).to be(true)
      expect(unavailable.available?).to be(false)
    end
  end

  describe "#stale?" do
    it "is stale once checked_at exceeds the ttl" do
      check = build(:model_availability_check, checked_at: 7.hours.ago, expires_at: nil)

      expect(check.stale?(6.hours)).to be(true)
    end

    it "is not stale within the ttl" do
      check = build(:model_availability_check, checked_at: 1.hour.ago, expires_at: nil)

      expect(check.stale?(6.hours)).to be(false)
    end

    it "is stale once expires_at has passed, even within the ttl window" do
      check = build(:model_availability_check, checked_at: 1.minute.ago, expires_at: 1.minute.ago)

      expect(check.stale?(6.hours)).to be(true)
    end
  end

  describe "scopes" do
    it ".global returns only account-agnostic rows" do
      global = create(:model_availability_check, account: nil)
      scoped = create(:model_availability_check, account: create(:account))

      expect(described_class.global).to contain_exactly(global)
      expect(described_class.global).not_to include(scoped)
    end
  end
end
