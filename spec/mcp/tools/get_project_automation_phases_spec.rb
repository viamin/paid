# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-002 @spec AUTOMATION-PHASES-014
RSpec.describe Tools::GetProjectAutomationPhases do
  it "inspects all phase settings without enabling rollout" do
    account = create(:account)
    owner = create(:user, :owner, account:)
    project = create(:project, account:, created_by: owner)
    session = create(:chat_session, account:, created_by: owner, project:)

    result = described_class.new(user: owner, session:).call(project_id: project.id)

    expect(result).to include(project_id: project.id, rollout_enabled: false, phases: have_attributes(size: 6))
  end
end
