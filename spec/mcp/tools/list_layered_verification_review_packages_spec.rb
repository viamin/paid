# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ListLayeredVerificationReviewPackages do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:obligation) { create(:layered_verification_obligation, project:, external_revision: "review-sha") }
  let(:audit) do
    run = create(:agent_run, project:, goal: "layered_verification_audit", status: "completed")
    create(:layered_verification_check_result, obligation:, agent_run: run,
      input_revision: { "target_revision" => "a" * 40 })
    run.update!(external_metadata: { "layered_verification" => {
      "obligation_ids" => [ obligation.id ], "target_revision" => "a" * 40,
      "plan" => {}, "coverage" => {}
    } })
    run
  end
  let!(:package) { LayeredVerification::ReviewPackages::Capture.call(agent_run: audit) }

  before do
    allow(FeatureFlags).to receive(:enabled?).and_call_original
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
  end

  # @spec LAYERED-VERIFY-023
  it "lists and gets review packages only through the selected authorized project" do
    list = described_class.new(user:, session: nil)
    get = Tools::GetLayeredVerificationReviewPackage.new(user:, session: nil)

    expect(list.dispatch(project_id: project.id).first).to include(id: package.id)
    expect(get.dispatch(project_id: project.id, review_package_id: package.id)).to include(id: package.id)

    other_project = create(:project)
    expect { get.dispatch(project_id: other_project.id, review_package_id: package.id) }
      .to raise_error(ActiveRecord::RecordNotFound)
  end

  # @spec LAYERED-VERIFY-012 LAYERED-VERIFY-023
  it "advertises an explicitly confirmed approval and records truthful MCP provenance without repair or release" do
    tool = Tools::ApproveLayeredVerificationReviewPackage.new(user:, session: nil)

    expect(Tools::Registry.mcp_definitions_for(user: user).map { |definition| definition[:name] })
      .to include("approve_layered_verification_review_package")
    expect {
      tool.dispatch(project_id: project.id, review_package_id: package.id, note: "Reviewed", confirmed: true)
    }.not_to change(AgentRun, :count)

    approval = package.reload.approvals.sole
    expect(approval.provenance).to include("surface" => "mcp", "note" => "Reviewed")
    expect(AgentRun.where(project:, goal: "layered_verification_repair")).to be_empty
  end

  # @spec LAYERED-VERIFY-012 LAYERED-VERIFY-023
  it "rejects disabled and stale approvals before an approval is created" do
    tool = Tools::ApproveLayeredVerificationReviewPackage.new(user:, session: nil)
    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(false)

    expect { tool.dispatch(project_id: project.id, review_package_id: package.id, confirmed: true) }
      .to raise_error(LayeredVerification::AuditAccess::FeatureDisabledError)
    expect(package.reload.approvals).to be_empty

    allow(FeatureFlags).to receive(:enabled?).with(:layered_verification_add_on, project:).and_return(true)
    obligation.update!(external_revision: "new-review-sha")
    expect { tool.dispatch(project_id: project.id, review_package_id: package.id, confirmed: true) }
      .to raise_error(LayeredVerification::ReviewPackages::Approve::StalePackageError)
    expect(package.reload.approvals).to be_empty
  end

  # @spec LAYERED-VERIFY-023
  it "refuses business-review approval for a reader without manage-issues permission" do
    reader = create(:user, account:)
    tool = Tools::ApproveLayeredVerificationReviewPackage.new(user: reader, session: nil)

    expect { tool.dispatch(project_id: project.id, review_package_id: package.id, confirmed: true) }
      .to raise_error(Pundit::NotAuthorizedError)
    expect(package.reload.approvals).to be_empty
  end
end
