# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProjectDelegation::IntentCheckpoint::Revisions do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:, title: "Import metrics", body: "Import them faithfully.") }

  it "derives stable design and acceptance revision tokens for a work item" do  # @spec PROJECT-DELEGATION-002
    revisions = described_class.for(issue)

    expect(revisions["design_revision"]).to start_with("design:")
    expect(revisions["acceptance_revision"]).to start_with("criteria:")
    expect(described_class.for(issue)).to eq(revisions)
  end

  it "changes the design revision when the work item's intent content changes" do  # @spec PROJECT-DELEGATION-002
    before = described_class.for(issue)["design_revision"]
    issue.update!(title: "A materially different request")

    expect(described_class.for(issue)["design_revision"]).not_to eq(before)
  end

  it "includes the linked approved design baseline in the design revision" do  # @spec PROJECT-DELEGATION-002
    feature_intent = create(:feature_intent, project:, approved_design_revision: "rev1")
    create(:feature_intent_issue, feature_intent:, issue:)
    before = described_class.for(issue)["design_revision"]

    feature_intent.update!(approved_design_revision: "rev2")

    expect(described_class.for(issue)["design_revision"]).not_to eq(before)
  end

  it "changes the acceptance revision when the recorded assessment changes" do  # @spec PROJECT-DELEGATION-002
    before = described_class.for(issue)["acceptance_revision"]
    assessment_run = create(:agent_run, :completed, project:, issue:)
    assessment_run.update!(reconciliation: { "assessment" => PartialCloseouts::Assessment.snapshot(
      assessment_run, { "criteria" => [ { "id" => "AC-1", "state" => "satisfied" } ], "gaps" => [] }
    ) })

    expect(described_class.for(issue)["acceptance_revision"]).not_to eq(before)
  end
end
