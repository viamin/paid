# frozen_string_literal: true

require "rails_helper"

RSpec.describe StagedCloseoutAdoption::Mappings do
  let(:project) { create(:project) }
  let(:maintainer) { create(:user, :owner, account: project.account) }
  let(:issue) { create(:issue, project:) }
  let!(:recipe) { create(:pre_commit_requirement, project:, account: project.account, enabled: true) }
  let(:attributes) { { criterion_key: "Keeps history", stage: "pre_merge", phase: "coding", target_shape: "source_pr_head", execution_path: "technical_prerequisite", target_key: recipe.id, freshness_seconds: 60 } }

  before do
    StagedCloseoutAdoption::Enroll.call(project:, actor: maintainer, enabled: true)
    create(:agent_run, :completed, project:, issue:, reconciliation: { "assessment" => {
      "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue), "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
      "criteria" => [ { "criterion" => "Keeps history", "state" => "unmet" } ], "gaps" => []
    } })
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-004
  it "invalidates admission after disable, revocation, or a changed reviewed recipe" do
    mapping = described_class.approve(project:, actor: maintainer, issue:, attributes:)
    expect(described_class.eligible_for(mapping:, project:, issue:)).to be_eligible

    StagedCloseoutAdoption::Enroll.call(project:, actor: maintainer, enabled: false)
    expect(described_class.eligible_for(mapping:, project:, issue:).reason).to eq("project_not_enrolled")
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-003 STAGED-CLOSEOUT-ADOPTION-004
  it "rejects a mapping when the latest current assessment removes its criterion" do
    mapping = described_class.approve(project:, actor: maintainer, issue:, attributes:)
    create(:agent_run, :completed, project:, issue:, reconciliation: { "assessment" => {
      "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
      "criteria" => [ { "criterion" => "A replacement criterion", "state" => "unmet" } ], "gaps" => []
    } })

    result = described_class.eligible_for(mapping:, project:, issue:)

    expect(result).not_to be_eligible
    expect(result.reason).to eq("criterion_not_current")
  end
end
