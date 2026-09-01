# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-AGENT-TOOLS-002
# @spec KNOWLEDGE-AGENT-TOOLS-005
# @spec KNOWLEDGE-AGENT-TOOLS-006
RSpec.describe Tools::KnowledgeBrowse do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }
  let(:project) { create(:project, account: account) }
  let(:project_version) { create(:project_version, project: project) }
  let(:collector_run) { create(:collector_run, project_version: project_version) }

  def create_artifact(scope_path:, identifier:, artifact_type: "symbol", status: "active")
    artifact = create(:knowledge_artifact,
      project: project,
      collector_run: collector_run,
      artifact_type: artifact_type,
      scope_path: scope_path,
      identifier: identifier,
      status: status)
    create(:knowledge_chunk, knowledge_artifact: artifact, project: project)
    artifact
  end

  describe "#call" do
    it "lists active artifacts of the given type with stable ids and uris" do
      artifact = create_artifact(scope_path: "app/models/user.rb", identifier: "User")

      result = tool.call(project_id: project.id, artifact_type: "symbol")

      expect(result[:artifact_type]).to eq("symbol")
      expect(result[:total_count]).to eq(1)
      expect(result[:artifacts]).to contain_exactly(
        hash_including(
          artifact_id: artifact.id,
          uri: "knowledge://#{project.id}/symbol/#{artifact.id}",
          identifier: "User",
          scope_path: "app/models/user.rb",
          chunk_count: 1
        )
      )
    end

    it "includes stale chunks in chunk_count, matching paid_knowledge_get visibility" do
      artifact = create_artifact(scope_path: "app/models/user.rb", identifier: "User")
      create(:knowledge_chunk, knowledge_artifact: artifact, project: project, status: "stale")
      create(:knowledge_chunk, knowledge_artifact: artifact, project: project, status: "deleted")

      result = tool.call(project_id: project.id, artifact_type: "symbol")

      expect(result[:artifacts]).to contain_exactly(hash_including(artifact_id: artifact.id, chunk_count: 2))
    end

    it "excludes artifacts of other types and stale artifacts" do
      create_artifact(scope_path: "config/routes.rb", identifier: "GET /x", artifact_type: "route")
      create_artifact(scope_path: "app/models/stale.rb", identifier: "Stale", status: "stale")

      result = tool.call(project_id: project.id, artifact_type: "symbol")

      expect(result[:artifacts]).to be_empty
      expect(result[:total_count]).to eq(0)
    end

    it "filters by scope_path prefix" do
      matching = create_artifact(scope_path: "app/models/user.rb", identifier: "User")
      create_artifact(scope_path: "app/controllers/users_controller.rb", identifier: "UsersController")

      result = tool.call(project_id: project.id, artifact_type: "symbol", scope_path_prefix: "app/models/")

      expect(result[:artifacts].map { |a| a[:artifact_id] }).to eq([ matching.id ])
    end

    it "bounds results with limit and offset" do
      3.times { |n| create_artifact(scope_path: "app/models/m#{n}.rb", identifier: "M#{n}") }

      result = tool.call(project_id: project.id, artifact_type: "symbol", limit: 2, offset: 1)

      expect(result[:limit]).to eq(2)
      expect(result[:offset]).to eq(1)
      expect(result[:total_count]).to eq(3)
      expect(result[:artifacts].size).to eq(2)
    end

    it "clamps limit to the max allowed" do
      result = tool.call(project_id: project.id, artifact_type: "symbol", limit: described_class::MAX_LIMIT + 50)

      expect(result[:limit]).to eq(described_class::MAX_LIMIT)
    end

    it "raises for projects outside the user's account" do
      other_project = create(:project)

      expect { tool.call(project_id: other_project.id, artifact_type: "symbol") }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  it "is read-only" do
    expect(described_class.write_operation?).to be false
  end
end
