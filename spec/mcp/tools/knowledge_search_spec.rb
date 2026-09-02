# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-AGENT-TOOLS-003
# @spec KNOWLEDGE-AGENT-TOOLS-005
# @spec KNOWLEDGE-AGENT-TOOLS-006
RSpec.describe Tools::KnowledgeSearch do
  include_context "without qdrant vector search"

  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }
  let(:project) { create(:project, account: account) }
  let(:project_version) { create(:project_version, project: project) }
  let(:collector_run) { create(:collector_run, project_version: project_version) }

  let!(:artifact) do
    create(:knowledge_artifact,
      project: project,
      collector_run: collector_run,
      artifact_type: "route",
      identifier: "POST /api/users",
      scope_path: "config/routes.rb")
  end

  let!(:chunk) do
    create(:knowledge_chunk,
      knowledge_artifact: artifact,
      project: project,
      content: "Route: POST /api/users\nController: api/users#create")
  end

  describe "#call" do
    it "returns bounded, structured search results with stable ids and uris" do
      result = tool.call(project_id: project.id, query: "POST /api/users", mode: "exact")

      expect(result[:project_id]).to eq(project.id)
      expect(result[:results]).to contain_exactly(
        hash_including(
          chunk_id: chunk.id,
          artifact_id: artifact.id,
          uri: "knowledge://#{project.id}/route/#{artifact.id}",
          artifact_type: "route",
          identifier: "POST /api/users",
          scope_path: "config/routes.rb"
        )
      )
      expect(result[:meta]).to include(mode: "exact")
    end

    it "truncates result content to the preview limit" do
      long_content = "x" * (described_class::CONTENT_LIMIT + 100)
      long_chunk_artifact = create(:knowledge_artifact,
        project: project, collector_run: collector_run, artifact_type: "route",
        identifier: "long content artifact", scope_path: "config/routes.rb")
      create(:knowledge_chunk, knowledge_artifact: long_chunk_artifact, project: project, content: long_content)

      result = tool.call(project_id: project.id, query: "long content artifact", mode: "exact")

      expect(result[:results].first[:content].length).to be <= described_class::CONTENT_LIMIT
    end

    it "raises when query is blank" do
      expect { tool.call(project_id: project.id, query: "   ") }
        .to raise_error(ArgumentError, "query is required")
    end

    it "clamps limit to the max allowed" do
      result = tool.call(project_id: project.id, query: "POST /api/users", mode: "exact", limit: described_class::MAX_LIMIT + 50)

      expect(result[:results].size).to be <= described_class::MAX_LIMIT
    end

    it "raises for projects outside the user's account" do
      other_project = create(:project)

      expect { tool.call(project_id: other_project.id, query: "users") }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  it "is read-only" do
    expect(described_class.write_operation?).to be false
  end
end
