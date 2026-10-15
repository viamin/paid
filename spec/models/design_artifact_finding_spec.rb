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
  end
end
