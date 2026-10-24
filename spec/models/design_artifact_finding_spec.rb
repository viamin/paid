# frozen_string_literal: true

require "rails_helper"

# @spec DESIGN-RECONCILIATION-001
RSpec.describe DesignArtifactFinding do
  describe "Inbox cache invalidation" do
    it "bumps the cache when an open finding is created" do
      finding = build(:design_artifact_finding)

      expect(Dashboard::CacheVersion).to receive(:bump).with(
        finding.project.account,
        scope: Dashboard::CacheVersion::INBOX_SCOPE
      )

      finding.save!
    end

    it "does not bump the cache when evidence changes" do
      finding = create(:design_artifact_finding)

      expect(Dashboard::CacheVersion).not_to receive(:bump)

      finding.update!(evidence: [ "Updated evidence" ])
    end

    it "bumps the cache when a finding leaves the open state" do
      finding = create(:design_artifact_finding)

      expect(Dashboard::CacheVersion).to receive(:bump).with(
        finding.project.account,
        scope: Dashboard::CacheVersion::INBOX_SCOPE
      )

      finding.resolve!
    end

    it "bumps the cache when a finding enters the open state" do
      finding = create(:design_artifact_finding, status: "resolved")

      expect(Dashboard::CacheVersion).to receive(:bump).with(
        finding.project.account,
        scope: Dashboard::CacheVersion::INBOX_SCOPE
      )

      finding.update!(status: "open")
    end

    it "does not bump the cache when a resolved finding is created" do
      finding = build(:design_artifact_finding, status: "resolved")

      expect(Dashboard::CacheVersion).not_to receive(:bump)

      finding.save!
    end

    # @spec OPERATOR-INBOX-019
    it "does not bump the cache when an informational finding is persisted" do
      finding = build(:design_artifact_finding, state: "deferred", status: "deferred")

      expect(Dashboard::CacheVersion).not_to receive(:bump)

      finding.save!
    end
  end

  # @spec OPERATOR-INBOX-019 DESIGN-RECONCILIATION-001
  describe ".actionable_state?" do
    it "treats only deferred artifact statuses as informational" do
      expect(described_class.actionable_state?("missing_tree")).to be(true)
      expect(described_class.actionable_state?("partial_tree")).to be(true)
      expect(described_class.actionable_state?("stale_metadata")).to be(true)
      expect(described_class.actionable_state?("unverifiable")).to be(true)
      expect(described_class.actionable_state?("deferred")).to be(false)
    end
  end

  # @spec OPERATOR-INBOX-019 DESIGN-RECONCILIATION-001
  describe "#unverifiable?" do
    it "identifies coverage that could not be read" do
      finding = build(:design_artifact_finding, state: "unverifiable")

      expect(finding).to be_unverifiable
    end
  end

  # @spec OPERATOR-INBOX-019 DESIGN-RECONCILIATION-001
  describe ".actionable_findings" do
    it "excludes informational deferred-state findings even while status is open" do
      project = create(:project)
      actionable = create(:design_artifact_finding, project:, account: project.account, state: "missing_tree")
      informational = create(:design_artifact_finding, project:, account: project.account, state: "deferred",
        evidence: [ "Artifact status is Draft" ])

      expect(project.design_artifact_findings.actionable_findings).to contain_exactly(actionable)
      expect(project.design_artifact_findings.open_findings).to include(informational)
    end

    it "keeps unverifiable coverage failures actionable" do
      project = create(:project)
      unavailable = create(:design_artifact_finding, project:, account: project.account, state: "unverifiable")

      expect(project.design_artifact_findings.actionable_findings).to contain_exactly(unavailable)
    end

    it "still excludes resolved actionable findings" do
      project = create(:project)
      resolved = create(:design_artifact_finding, project:, account: project.account,
        status: "resolved", resolved_at: Time.current)

      expect(project.design_artifact_findings.actionable_findings).not_to include(resolved)
    end
  end
end
