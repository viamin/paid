# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-AGENT-TOOLS-001
# @spec KNOWLEDGE-AGENT-TOOLS-005
# @spec KNOWLEDGE-AGENT-TOOLS-006
RSpec.describe Tools::KnowledgeMap do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }
  let(:project) { create(:project, account: account) }
  let(:project_version) { create(:project_version, project: project) }
  let(:collector_run) { create(:collector_run, project_version: project_version) }

  def create_artifact(artifact_type:, status: "active")
    create(:knowledge_artifact,
      project: project,
      collector_run: collector_run,
      artifact_type: artifact_type,
      status: status)
  end

  describe "#call" do
    it "returns active artifact counts grouped by type" do
      create_artifact(artifact_type: "route")
      create_artifact(artifact_type: "route")
      create_artifact(artifact_type: "symbol")
      create_artifact(artifact_type: "symbol", status: "stale")

      result = tool.call(project_id: project.id)

      expect(result[:project_id]).to eq(project.id)
      expect(result[:total_artifacts]).to eq(3)
      expect(result[:artifact_types]).to contain_exactly(
        { artifact_type: "route", count: 2 },
        { artifact_type: "symbol", count: 1 }
      )
    end

    it "returns an empty map when the project has no active artifacts" do
      result = tool.call(project_id: project.id)

      expect(result).to eq(project_id: project.id, total_artifacts: 0, artifact_types: [])
    end

    it "raises for projects outside the user's account" do
      other_project = create(:project)

      expect { tool.call(project_id: other_project.id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  it "is read-only" do
    expect(described_class.write_operation?).to be false
  end
end
