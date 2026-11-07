# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-005
RSpec.describe Tools::GetProjectDelegation do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:project) { create(:project, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }

  before { FeatureFlags.enable!(:project_delegation, project:) }

  def authorize_review(work_item:)
    create(:bounded_delegated_action,
      project: project,
      issue: work_item,
      action: "review",
      evidence: Automation::DelegatedActionAdmission.admission_evidence(
        work_item: work_item, action: "review", acceptance_refs: [ "AC-1" ], stop_before_phase: "merge"
      ))
  end

  it "returns the project's delegation projection" do
    work_item = create(:issue, project: project)
    authorization = authorize_review(work_item: work_item)

    result = tool.call(project_id: project.id)

    expect(result).to include(
      project_id: project.id,
      authorizations: [ hash_including(
        id: authorization.id, action: "review", in_force: true,
        authority: hash_including(permitted: true)
      ) ]
    )
    expect(result).to include(:signature)
    expect(result).not_to include(:phase_authority)
  end

  it "scopes the projection to a requested work item" do
    work_item = create(:issue, project: project)
    other_item = create(:issue, project: project)
    authorize_review(work_item: other_item)

    result = tool.call(project_id: project.id, issue_id: work_item.id)

    expect(result.fetch(:work_item_id)).to eq(work_item.id)
    expect(result.fetch(:authorizations)).to be_empty
  end

  it "raises when the requested work item is outside the project" do
    other_item = create(:issue)

    expect { tool.call(project_id: project.id, issue_id: other_item.id) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end

  it "raises for projects outside the user's account" do
    other_project = create(:project)

    expect { tool.call(project_id: other_project.id) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end

  it "raises until the project opts in" do
    FeatureFlags.disable!(:project_delegation, project:)

    expect { tool.call(project_id: project.id) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end
end
