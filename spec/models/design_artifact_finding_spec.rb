# frozen_string_literal: true

require "rails_helper"

# @spec DESIGN-RECONCILIATION-001
RSpec.describe DesignArtifactFinding do
  describe "Inbox cache invalidation" do
    it "is registered for status changes" do
      callback = described_class._commit_callbacks.find do |item|
        item.kind == :after && item.filter == :bump_inbox_cache_version
      end

      expect(callback.instance_variable_get(:@if)).to include(:saved_change_to_status?)
    end

    it "does not mark an evidence update as a status change" do
      finding = create(:design_artifact_finding)

      finding.update!(evidence: [ "Updated evidence" ])

      expect(finding.saved_change_to_status?).to be(false)
    end

    it "marks resolving a finding as a status change" do
      finding = create(:design_artifact_finding)

      finding.resolve!

      expect(finding.saved_change_to_status?).to be(true)
    end
  end
end
