# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::UpdateIssueControlState do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:, label_integration_mode: "ignored") }
  let(:session) { create(:chat_session, account:, created_by: owner, project:) }
  let(:issue) { create(:issue, project:) }

  def call(action:, **kwargs)
    described_class.new(user: owner, session:).call(
      project_id: project.id, issue_id: issue.id, action:, confirmed: true, **kwargs
    )
  end

  it "persists ignored-mode auto-pick exclusion and priority" do # @spec LABEL-CONTROL-002 LABEL-CONTROL-003
    call(action: "exclude_from_auto_pick", reason: "Awaiting product decision")
    call(action: "set_priority", priority: "P1")

    expect(issue.reload).to have_attributes(auto_pick_excluded_reason: "Awaiting product decision", control_priority: "P1")
  end

  it "rejects a control action outside ignored mode" do # @spec LABEL-CONTROL-001
    project.update!(label_integration_mode: "read_only")

    expect { call(action: "pause") }.to raise_error(ArgumentError, /ignored label mode/)
  end
end
