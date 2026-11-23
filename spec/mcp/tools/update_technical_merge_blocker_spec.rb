# frozen_string_literal: true

require "rails_helper"

# @spec AUTO-MERGE-012
RSpec.describe Tools::UpdateTechnicalMergeBlocker do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account:) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, :pull_request, project:) }
  let(:owner) { create(:issue, project:) }
  let(:tool) { described_class.new(user:, session: nil) }
  let(:arguments) do
    { project_id: project.id, issue_id: issue.id, action: "record", key: "ci", head_sha: "a" * 40,
      reason: "Reproduced failure", owner_issue_id: owner.id, release_condition: "Pass current regression", confirmed: true }
  end

  it "exposes confirmed technical state through the shared chat/MCP registry" do
    expect(Tools::Registry.find("update_technical_merge_blocker")).to eq(described_class)
    expect(described_class.mcp_available?).to be(true)
    result = tool.call(**arguments)
    expect(result.fetch(:technical_merge_blockers).sole).to include("key" => "ci")
    expect(issue.reload.labels).to be_empty
  end

  it "requires confirmation without changing state" do
    expect { tool.call(**arguments.merge(confirmed: false)) }.to raise_error(ArgumentError, /Confirmation/)
    expect(issue.reload.technical_merge_blockers).to be_empty
  end

  it "rejects viewer writes" do
    viewer = create(:user, :viewer, account:)
    expect { described_class.new(user: viewer, session: nil).call(**arguments) }.to raise_error(Pundit::NotAuthorizedError)
    expect(issue.reload.technical_merge_blockers).to be_empty
  end

  it "cannot address another tenant's PR through an allowed project" do
    foreign = create(:issue, :pull_request)
    expect { tool.call(**arguments.merge(issue_id: foreign.id)) }.to raise_error(ActiveRecord::RecordNotFound)
    expect(foreign.reload.technical_merge_blockers).to be_empty
  end
end
