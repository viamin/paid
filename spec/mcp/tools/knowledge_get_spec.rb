# frozen_string_literal: true

require "rails_helper"

# @spec KNOWLEDGE-AGENT-TOOLS-004
# @spec KNOWLEDGE-AGENT-TOOLS-005
# @spec KNOWLEDGE-AGENT-TOOLS-006
RSpec.describe Tools::KnowledgeGet do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }
  let(:project) { create(:project, account: account) }
  let(:project_version) { create(:project_version, project: project, commit_sha: "a" * 40) }
  let(:collector_run) { create(:collector_run, project_version: project_version) }

  let!(:artifact) do
    create(:knowledge_artifact,
      project: project,
      collector_run: collector_run,
      artifact_type: "symbol",
      identifier: "User",
      scope_path: "app/models/user.rb")
  end

  describe "#call" do
    it "returns the artifact with its active chunks in order" do
      chunk_two = create(:knowledge_chunk, knowledge_artifact: artifact, project: project, sequence: 1, content: "second")
      chunk_one = create(:knowledge_chunk, knowledge_artifact: artifact, project: project, sequence: 0, content: "first")

      result = tool.call(project_id: project.id, artifact_id: artifact.id)

      expect(result).to include(
        artifact_id: artifact.id,
        uri: "knowledge://#{project.id}/symbol/#{artifact.id}",
        artifact_type: "symbol",
        identifier: "User",
        scope_path: "app/models/user.rb",
        chunk_count: 2,
        truncated: false
      )
      expect(result[:chunks].map { |c| c[:chunk_id] }).to eq([ chunk_one.id, chunk_two.id ])
      expect(result[:project_version]).to eq(commit_sha: "a" * 40, committed_at: project_version.committed_at.iso8601)
    end

    it "excludes deleted chunks" do
      create(:knowledge_chunk, knowledge_artifact: artifact, project: project, status: "deleted")

      result = tool.call(project_id: project.id, artifact_id: artifact.id)

      expect(result[:chunks]).to be_empty
      expect(result[:chunk_count]).to eq(0)
    end

    it "bounds the number of chunks and flags truncation" do
      stub_const("Tools::KnowledgeGet::MAX_CHUNKS", 1)
      create(:knowledge_chunk, knowledge_artifact: artifact, project: project, sequence: 0)
      create(:knowledge_chunk, knowledge_artifact: artifact, project: project, sequence: 1)

      result = tool.call(project_id: project.id, artifact_id: artifact.id)

      expect(result[:chunks].size).to eq(1)
      expect(result[:chunk_count]).to eq(2)
      expect(result[:truncated]).to be true
    end

    it "truncates chunk content to the per-chunk limit and flags truncation" do
      stub_const("Tools::KnowledgeGet::CHUNK_CONTENT_LIMIT", 10)
      create(:knowledge_chunk, knowledge_artifact: artifact, project: project, content: "x" * 50)

      result = tool.call(project_id: project.id, artifact_id: artifact.id)

      expect(result[:chunks].first[:content].length).to eq(10)
      expect(result[:truncated]).to be true
    end

    it "does not flag truncation when content and chunk count are within bounds" do
      create(:knowledge_chunk, knowledge_artifact: artifact, project: project, content: "short")

      result = tool.call(project_id: project.id, artifact_id: artifact.id)

      expect(result[:truncated]).to be false
    end

    it "raises for an artifact outside the project" do
      other_artifact = create(:knowledge_artifact)

      expect { tool.call(project_id: project.id, artifact_id: other_artifact.id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises for projects outside the user's account" do
      other_project = create(:project)

      expect { tool.call(project_id: other_project.id, artifact_id: artifact.id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  it "is read-only" do
    expect(described_class.write_operation?).to be false
  end
end
