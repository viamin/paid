# frozen_string_literal: true

require "rails_helper"

RSpec.describe SupervisorSnapshot do
  describe "sanitized persistence" do
    it "accepts typed operational facts and bounds the retained digest" do # @spec OPERATIONAL-SUPERVISOR-001, OPERATIONAL-SUPERVISOR-002, OPERATIONAL-SUPERVISOR-003
      snapshot = build(:supervisor_snapshot)

      expect(snapshot).to be_valid
    end

    it "retains a typed denominator and rejects duplicate or excessive metrics" do # @spec OPERATIONAL-SUPERVISOR-002
      metrics = OperationalSupervisor::SanitizedPayload::METRIC_NAMES.map { |name| { "name" => name, "status" => "available" } }
      duplicate_metrics = build(:supervisor_snapshot, digest: { "schema_version" => 1, "metrics" => [ metrics.first, metrics.first.dup ] })
      excessive_metrics = build(:supervisor_snapshot, digest: { "schema_version" => 1, "metrics" => metrics + [ metrics.first ] })
      invalid_denominator = build(:supervisor_snapshot, metric_provenance: { "window" => "PT24H", "denominator" => "12", "inclusion_rule" => "enabled_projects_only" })

      expect(build(:supervisor_snapshot, metric_provenance: { "window" => "PT24H", "denominator" => 12, "inclusion_rule" => "enabled_projects_only" })).to be_valid
      expect(duplicate_metrics).to be_invalid
      expect(excessive_metrics).to be_invalid
      expect(invalid_denominator).to be_invalid
      expect(duplicate_metrics.errors[:digest]).to include("contains unsupported or unsafe fields")
      expect(excessive_metrics.errors[:digest]).to include("contains unsupported or unsafe fields")
      expect(invalid_denominator.errors[:metric_provenance]).to include("contains unsupported or unsafe fields")
    end

    it "rejects authored content and secrets from its durable payloads" do # @spec OPERATIONAL-SUPERVISOR-001
      snapshot = build(:supervisor_snapshot, digest: { "issue_body" => "customer text", "token" => "secret" })

      expect(snapshot).to be_invalid
      expect(snapshot.errors[:digest]).to include("contains unsupported or unsafe fields")
    end

    it "rejects unrecognized fields from durable payloads" do # @spec OPERATIONAL-SUPERVISOR-001
      snapshot = build(:supervisor_snapshot, digest: { "issue_title" => "customer-authored text" })

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
