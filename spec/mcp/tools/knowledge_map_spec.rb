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

  def create_artifact(artifact_type:, status: "active", scope_path: nil)
    create(:knowledge_artifact,
      project: project,
      collector_run: collector_run,
      artifact_type: artifact_type,
      status: status,
      scope_path: scope_path)
  end

  describe "#call" do
    it "returns active and stale artifact counts grouped by type, matching Knowledge::Map::Build" do
      create_artifact(artifact_type: "route", scope_path: "app/controllers/a.rb")
      create_artifact(artifact_type: "route", scope_path: "app/controllers/b.rb")
      create_artifact(artifact_type: "symbol", scope_path: "app/models/user.rb")
      create_artifact(artifact_type: "symbol", status: "stale", scope_path: "app/models/user.rb")

      result = tool.call(project_id: project.id)
      overview = Knowledge::Map::Build.call(project: project)

      expect(result[:project_id]).to eq(project.id)
      expect(result[:total_artifacts]).to eq(4)
      expect(result[:artifact_types]).to contain_exactly(
        { artifact_type: "route", count: 2 },
        { artifact_type: "symbol", count: 2 }
      )
      expect(result[:top_scopes]).to eq(overview[:top_scopes])
    end

    it "returns an empty map when the project has no artifacts" do
      result = tool.call(project_id: project.id)

      expect(result).to eq(project_id: project.id, total_artifacts: 0, artifact_types: [], top_scopes: [])
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
