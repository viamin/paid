# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::GrepRepo do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }
  let(:project) { create(:project, account: account) }
  let(:github_client) { instance_double(GithubClient) }
  let(:identity) { "project-token:#{project.github_token.name}" }
  let(:resolved_client) { Tools::RepoReadClientResolver::ResolvedClient.new(client: github_client, identity:) }

  before do
    allow(tool).to receive(:resolve_repo_read_client).and_return(resolved_client)
    allow(github_client).to receive(:search_code)
  end

  describe "#call" do
    it "prefers the chatting user's matching GitHub token" do
      items = [
        Struct.new(:path, :name, :html_url).new("app/models/foo.rb", "foo.rb", "https://github.com/owner/repo/blob/main/app/models/foo.rb")
      ]
      search_result = Struct.new(:total_count, :items).new(1, items)
      allow(tool).to receive(:resolve_repo_read_client).and_return(
        Tools::RepoReadClientResolver::ResolvedClient.new(client: github_client, identity: "user-token:Chat Token")
      )
      allow(github_client).to receive(:search_code).and_return(search_result)

      result = tool.call(project_id: project.id, query: "def authorize")

      expect(result[:total_count]).to eq(1)
      expect(result[:matches].size).to eq(1)
      expect(result[:matches].first[:path]).to eq("app/models/foo.rb")
      expect(result[:identity]).to include("user-token")
    end

    it "falls back to the project credential when the user has no matching token" do
      search_result = Struct.new(:total_count, :items).new(0, [])
      allow(github_client).to receive(:search_code).and_return(search_result)

      result = tool.call(project_id: project.id, query: "def authorize")

      expect(result[:identity]).to include("project-token")
    end

    it "qualifies query with repo scope" do
      search_result = Struct.new(:total_count, :items).new(0, [])
      allow(github_client).to receive(:search_code).and_return(search_result)

      tool.call(project_id: project.id, query: "def authorize")

      expect(github_client).to have_received(:search_code).with("repo:#{project.full_name} def authorize", hash_including(:per_page))
    end

    it "includes path_filter in query" do
      search_result = Struct.new(:total_count, :items).new(0, [])
      allow(github_client).to receive(:search_code).and_return(search_result)

      tool.call(project_id: project.id, query: "class Foo", path_filter: "app/models")

      expect(github_client).to have_received(:search_code).with("repo:#{project.full_name} class Foo path:app/models", hash_including(:per_page))
    end

    it "strips injected GitHub qualifiers from the user query" do
      search_result = Struct.new(:total_count, :items).new(0, [])
      allow(github_client).to receive(:search_code).and_return(search_result)

      tool.call(project_id: project.id, query: "secret_key repo:other/private-repo org:secret-org path:config", path_filter: "app/models")

      expect(github_client).to have_received(:search_code).with(
        "repo:#{project.full_name} secret_key path:app/models",
        hash_including(:per_page)
      )
    end

    it "returns empty results for qualifier-only queries" do
      result = tool.call(project_id: project.id, query: "repo:other/private-repo org:secret-org path:config")

      expect(github_client).not_to have_received(:search_code)
      expect(result).to eq(matches: [], total_count: 0, identity: identity)
    end

    it "sanitizes injected qualifiers from path_filter" do
      search_result = Struct.new(:total_count, :items).new(0, [])
      allow(github_client).to receive(:search_code).and_return(search_result)

      tool.call(project_id: project.id, query: "secret_key", path_filter: "app/models repo:other/private-repo")

      expect(github_client).to have_received(:search_code).with(
        "repo:#{project.full_name} secret_key path:app/models",
        hash_including(:per_page)
      )
    end

    it "returns empty results when no matches" do
      search_result = Struct.new(:total_count, :items).new(0, [])
      allow(github_client).to receive(:search_code).and_return(search_result)

      result = tool.call(project_id: project.id, query: "nonexistent_pattern_xyz")

      expect(result[:matches]).to eq([])
      expect(result[:total_count]).to eq(0)
    end

    it "raises for project in another account" do
      other_project = create(:project)

      expect { tool.call(project_id: other_project.id, query: "test") }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe ".description_for" do
    # @spec CHAT-API-012
    it "returns the plain description when the session has no project" do
      session_without_project = build(:chat_session, account: account, created_by: user)

      expect(described_class.description_for(session: session_without_project)).to eq(described_class.description)
    end

    it "returns the plain description when the session's project knowledge is not ready" do
      pending_project = create(:project, account: account, knowledge_status: "collecting")
      session_with_pending_project = build(:chat_session, account: account, created_by: user, project: pending_project)

      expect(described_class.description_for(session: session_with_pending_project)).to eq(described_class.description)
    end

    it "demotes the description to a fallback note when the session's project knowledge is ready" do
      ready_project = create(:project, account: account, knowledge_status: "ready")
      session_with_ready_project = build(:chat_session, account: account, created_by: user, project: ready_project)

      description = described_class.description_for(session: session_with_ready_project)

      expect(description).to start_with(described_class.description)
      expect(description).to include("Fallback only").and include("search_code")
    end
  end
end
