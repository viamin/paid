# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-008
RSpec.describe Tools::RevokeContinuationGrant do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:session) { create(:chat_session, account:, created_by: owner, project:) }

  it "requires confirmation and revokes only the scoped active grant" do
    grant = create(:work_item_continuation_grant, project:, issue: create(:issue, project:))

    expect { described_class.new(user: owner, session:).call(project_id: project.id, grant_id: grant.id, confirmed: false) }.to raise_error(ArgumentError, /Confirmation required/)
    expect(described_class.new(user: owner, session:).call(project_id: project.id, grant_id: grant.id, confirmed: true)).to include(revoked: true)
    expect(described_class.new(user: owner, session:).call(project_id: project.id, grant_id: grant.id, confirmed: true)).to include(revoked: false)
  end

  it "does not resolve a foreign project's grant" do
    other_grant = create(:work_item_continuation_grant)

    expect {
      described_class.new(user: owner, session:).call(project_id: project.id, grant_id: other_grant.id, confirmed: true)
    }.to raise_error(ActiveRecord::RecordNotFound)
  end
end
