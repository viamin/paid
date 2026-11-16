# frozen_string_literal: true

require "rails_helper"

RSpec.describe StagedCloseoutAdoption::Mappings do
  let(:project) { create(:project) }
  let(:maintainer) { create(:user, :owner, account: project.account) }
  let(:issue) { create(:issue, project:) }
  let!(:recipe) { create(:pre_commit_requirement, project:, account: project.account, enabled: true) }
  let(:attributes) do
    { criterion_key: "The report renders", stage: "pre_merge", phase: "coding", target_shape: "source_pr_head",
      execution_path: "technical_prerequisite", target_key: recipe.id, freshness_seconds: 3600, retry_policy: { "max_attempts" => 1 } }
  end

  before do
    StagedCloseoutAdoption::Enroll.call(project:, actor: maintainer, enabled: true)
    create(:agent_run, :completed, project:, issue:, reconciliation: { "assessment" => {
      "source_revision" => PartialCloseouts::Assessment.source_revision_for(issue),
      "intent_revision" => PartialCloseouts::Assessment.intent_revision_for(issue),
      "criteria" => [ { "criterion" => "The report renders", "state" => "unmet" } ], "gaps" => []
    } })
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-002 STAGED-CLOSEOUT-ADOPTION-003
  it "pins an authorized reviewed recipe and preserves the superseded revision" do
    first = described_class.approve(project:, actor: maintainer, issue:, attributes:)
    second = described_class.approve(project:, actor: maintainer, issue:, attributes: attributes.merge(freshness_seconds: 7200))

    expect(first.reload).to have_attributes(status: "superseded", invalidation_reason: "replaced_by_review")
    expect(second).to have_attributes(status: "approved", revision: 2, reviewed_by: maintainer)
    expect(second.target_digest).to be_present
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-002
  it "attributes revocation and appends a new revision after reapproval" do
    mapping = described_class.approve(project:, actor: maintainer, issue:, attributes:)
    revoker = create(:user, :owner, account: project.account)

    described_class.revoke(mapping:, project:, actor: revoker, issue:, attributes: {})
    replacement = described_class.approve(project:, actor: maintainer, issue:, attributes:)

    expect(mapping.reload).to have_attributes(status: "revoked", invalidated_by: revoker, invalidated_at: be_present)
    expect(replacement).to have_attributes(status: "approved", revision: 2)
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-003
  it "rejects unknown criteria, mismatched stages, unavailable recipes, and an untrusted actor" do
    expect { described_class.approve(project:, actor: maintainer, issue:, attributes: attributes.merge(criterion_key: "Invented")) }
      .to raise_error(StagedCloseoutAdoption::Error, /criterion/)
    expect { described_class.approve(project:, actor: maintainer, issue:, attributes: attributes.merge(phase: "operations")) }
      .to raise_error(StagedCloseoutAdoption::Error, /stage/)
    expect { described_class.approve(project:, actor: maintainer, issue:, attributes: attributes.merge(target_key: -1)) }
      .to raise_error(StagedCloseoutAdoption::Error, /recipe/)
    expect { described_class.approve(project:, actor: create(:user, account: project.account), issue:, attributes:) }
      .to raise_error(StagedCloseoutAdoption::Error, /authorized/)
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-003
  it "rejects incomplete mapping attributes with a domain validation error" do
    %i[criterion_key stage phase target_shape execution_path target_key freshness_seconds].each do |key|
      expect { described_class.approve(project:, actor: maintainer, issue:, attributes: attributes.except(key)) }
        .to raise_error(StagedCloseoutAdoption::Error, /missing required mapping attributes: #{key}/)
    end
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-003
  it "rejects reviewer-scoped recipes that eligibility cannot resolve without an actor" do
    reviewer_recipe = create(:pre_commit_requirement, user: maintainer, account: project.account, enabled: true)

    expect { described_class.approve(project:, actor: maintainer, issue:, attributes: attributes.merge(target_key: reviewer_recipe.id)) }
      .to raise_error(StagedCloseoutAdoption::Error, /recipe is unavailable or unauthorized/)
  end

  # @spec STAGED-CLOSEOUT-ADOPTION-003
  it "does not permit a reviewer or issue from another tenant" do
    other_project = create(:project)
    other_owner = create(:user, :owner, account: other_project.account)

    expect { described_class.approve(project:, actor: other_owner, issue:, attributes:) }
      .to raise_error(StagedCloseoutAdoption::Error, /authorized/)
    expect { described_class.approve(project:, actor: maintainer, issue: create(:issue, project: other_project), attributes:) }
      .to raise_error(StagedCloseoutAdoption::Error, /project/)
  end
end
