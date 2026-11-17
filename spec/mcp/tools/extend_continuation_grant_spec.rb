# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-009
RSpec.describe Tools::ExtendContinuationGrant do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:session) { create(:chat_session, account:, created_by: owner, project:) }

  it "rejects an extension through merge without merge delegation" do
    member = create(:user, :member, account:)
    grant = create(:work_item_continuation_grant, project:, issue: create(:issue, project:), start_phase: "coding", endpoint: "coding")

    expect {
      described_class.new(user: member, session:).call(project_id: project.id, grant_id: grant.id, endpoint: "merge", confirmed: true)
    }.to raise_error(Pundit::NotAuthorizedError)
  end

  it "rejects an inactive grant extension" do
    grant = create(:work_item_continuation_grant, project:, issue: create(:issue, project:), completed_at: Time.current)

    expect {
      described_class.new(user: owner, session:).call(project_id: project.id, grant_id: grant.id, endpoint: "merge", confirmed: true)
    }.to raise_error(ArgumentError, /inactive/)
  end
end
