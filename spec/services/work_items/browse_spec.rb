# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkItems::Browse do
  let(:project) { create(:project) }
  let(:account) { project.account }

  before { account.tenant_setting!.update!(features: { "unified_work_items" => true }) }

  it "shows unassigned work first and filters by provider" do
    # @spec UNIFIED-WORK-ITEMS-004
    assigned = create(:work_item, account:, provider: "linear")
    create(:work_item_assignment, account:, work_item: assigned, project:)
    unassigned = create(:work_item, account:, provider: "linear")
    create(:work_item, account:, provider: "github")

    result = described_class.call(account:, provider: "linear")

    expect(result.to_a).to eq([ unassigned, assigned ])
  end

  it "filters by native project id" do
    matching = create(:work_item, :with_native_project, account:)
    create(:work_item, account:, native_project_id: "other-project")

    result = described_class.call(account:, native_project_id: "linear-project-1")

    expect(result).to contain_exactly(matching)
  end

  it "filters to items needing review" do
    flagged = create(:work_item, account:, assignment_review_flagged_at: Time.current)
    create(:work_item, account:)

    result = described_class.call(account:, needing_review: true)

    expect(result).to contain_exactly(flagged)
  end

  it "returns nothing while the rollout guard is disabled" do
    # @spec UNIFIED-WORK-ITEMS-009
    other_account = create(:account)
    create(:work_item, account: other_account)

    result = described_class.call(account: other_account)

    expect(result.to_a).to eq([])
  end
end
