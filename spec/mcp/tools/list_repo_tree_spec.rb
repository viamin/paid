# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::ListRepoTree do
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
    allow(github_client).to receive(:contents)
  end

  describe "#call" do
    it "prefers the chatting user's matching GitHub token" do
      root_entries = [
        Struct.new(:name, :path, :type, :size).new("README.md", "README.md", "file", 100),
        Struct.new(:name, :path, :type, :size).new("app", "app", "dir", 0)
      ]
      allow(tool).to receive(:resolve_repo_read_client).and_return(
        Tools::RepoReadClientResolver::ResolvedClient.new(client: github_client, identity: "user-token:Chat Token")
      )
      allow(github_client).to receive(:contents).and_return(root_entries)

      result = tool.call(project_id: project.id)

      expect(result[:entries].size).to eq(2)
      expect(result[:entries].first[:path]).to eq("README.md")
      expect(result[:identity]).to include("user-token")
      expect(github_client).to have_received(:contents).with(project.full_name, hash_including(path: "", ref: project.default_branch))
    end

    it "falls back to the project credential when the user has no matching token" do
      root_entries = [
        Struct.new(:name, :path, :type, :size).new("README.md", "README.md", "file", 100)
      ]
      allow(github_client).to receive(:contents).and_return(root_entries)

      result = tool.call(project_id: project.id)

      expect(result[:identity]).to include("project-token")
    end

    it "returns directory entries for a specific path" do
      dir_entries = [
        Struct.new(:name, :path, :type, :size).new("foo.rb", "app/models/foo.rb", "file", 200),
        Struct.new(:name, :path, :type, :size).new("bar.rb", "app/models/bar.rb", "file", 300)
      ]
      allow(github_client).to receive(:contents).and_return(dir_entries)

      result = tool.call(project_id: project.id, path: "app/models")

      expect(result[:entries].size).to eq(2)
      expect(result[:path]).to eq("app/models")
    end

    it "returns error for not-found path" do
      allow(github_client).to receive(:contents).and_raise(GithubClient::NotFoundError, "Not found")

      result = tool.call(project_id: project.id, path: "nonexistent")

      expect(result[:error]).to include("not found")
    end

    it "returns error when path is a file" do
      file_entry = Struct.new(:name, :path, :type, :size).new("README.md", "README.md", "file", 100)
      allow(github_client).to receive(:contents).and_return(file_entry)

      result = tool.call(project_id: project.id, path: "README.md")

      expect(result[:error]).to include("not found")
    end

    it "raises for project in another account" do
      other_project = create(:project)

      expect { tool.call(project_id: other_project.id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
