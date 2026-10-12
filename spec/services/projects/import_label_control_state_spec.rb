# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::ImportLabelControlState do
  describe ".call" do
    it "imports open paused issues and escalated pull requests without changing unrelated work" do # @spec LABEL-INTEGRATION-005
      project = create(:project)
      paused = create(:issue, project:, labels: [ Issue::PAUSED_LABEL ])
      escalated = create(:issue, :pull_request, project:, labels: [ Issue::ESCALATED_LABEL ], pr_review_phase: "ready")
      closed = create(:issue, :closed, project:, labels: [ Issue::PAUSED_LABEL ])

      result = described_class.call(project:)

      expect(result).to have_attributes(paused: 1, escalated: 1)
      expect(paused.reload).to be_paused
      expect(escalated.reload).to be_escalated_phase
      expect(closed.reload).not_to be_paused
    end

    it "is idempotent" do # @spec LABEL-INTEGRATION-007
      project = create(:project)
      create(:issue, project:, labels: [ Issue::PAUSED_LABEL ])

      described_class.call(project:)

      expect(described_class.call(project:)).to have_attributes(paused: 0, escalated: 0)
    end
  end
end
