# frozen_string_literal: true

require "rails_helper"

RSpec.describe SupervisorSnapshot do
  describe "sanitized persistence" do
    it "accepts typed operational facts and bounds the retained digest" do # @spec OPERATIONAL-SUPERVISOR-001, OPERATIONAL-SUPERVISOR-002, OPERATIONAL-SUPERVISOR-003
      snapshot = build(:supervisor_snapshot)

      expect(snapshot).to be_valid
    end

    it "retains bounded values and per-metric provenance" do # @spec OPERATIONAL-SUPERVISOR-002
      digest = {
        "schema_version" => 1,
        "metrics" => [
          { "name" => "conversion", "status" => "available", "value" => 0.75 },
          { "name" => "queue_starvation", "status" => "available", "value" => 12 }
        ]
      }
      provenance = [
        { "name" => "conversion", "window" => "PT24H", "denominator" => 20, "inclusion_rule" => "enabled_projects_only" },
        { "name" => "queue_starvation", "window" => "PT6H", "denominator" => 4, "inclusion_rule" => "enabled_projects_only" }
      ]

      snapshot = build(:supervisor_snapshot, digest:, metric_provenance: provenance)

      expect(snapshot).to be_valid
      expect(snapshot.digest.fetch("metrics").pluck("value")).to eq([ 0.75, 12 ])
      expect(snapshot.metric_provenance.pluck("window", "denominator")).to eq([ [ "PT24H", 20 ], [ "PT6H", 4 ] ])
    end

    it "rejects duplicate and excessive metrics" do # @spec OPERATIONAL-SUPERVISOR-002
      metrics = OperationalSupervisor::SanitizedPayload::METRIC_NAMES.map do |name|
        { "name" => name, "status" => "available", "value" => 1 }
      end
      duplicate_metrics = build(:supervisor_snapshot, digest: { "schema_version" => 1, "metrics" => [ metrics.first, metrics.first.dup ] })
      excessive_metrics = build(:supervisor_snapshot, digest: { "schema_version" => 1, "metrics" => metrics + [ metrics.first ] })

      expect(duplicate_metrics).to be_invalid
      expect(excessive_metrics).to be_invalid
      expect(duplicate_metrics.errors[:digest]).to include("contains unsupported or unsafe fields")
      expect(excessive_metrics.errors[:digest]).to include("contains unsupported or unsafe fields")
    end

    it "rejects invalid metric values and provenance" do # @spec OPERATIONAL-SUPERVISOR-002
      metric = { "name" => "queue_starvation", "status" => "available", "value" => 1 }
      unbounded_value = build(:supervisor_snapshot, digest: { "schema_version" => 1, "metrics" => [ metric.merge("value" => 10**16) ] })
      missing_value = build(:supervisor_snapshot, digest: { "schema_version" => 1, "metrics" => [ metric.merge("value" => nil) ] })
      mismatched_provenance = build(:supervisor_snapshot, metric_provenance: [
        { "name" => "conversion", "window" => "PT24H", "denominator" => 12, "inclusion_rule" => "enabled_projects_only" }
      ])
      invalid_denominator = build(:supervisor_snapshot, metric_provenance: [
        { "name" => "queue_starvation", "window" => "PT24H", "denominator" => "12", "inclusion_rule" => "enabled_projects_only" }
      ])

      expect(unbounded_value).to be_invalid
      expect(missing_value).to be_invalid
      expect(mismatched_provenance).to be_invalid
      expect(invalid_denominator).to be_invalid
      expect(unbounded_value.errors[:digest]).to include("contains unsupported or unsafe fields")
      expect(missing_value.errors[:digest]).to include("contains unsupported or unsafe fields")
      expect(mismatched_provenance.errors[:metric_provenance]).to include("must describe each metric exactly once")
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
