# frozen_string_literal: true

require "rails_helper"

# @spec CHAT-API-010
RSpec.describe Tools::RepoReadClientResolver do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:project) { create(:project, account: account) }
  let(:project_github_client) { instance_double(GithubClient) }
  let(:user_github_client) { instance_double(GithubClient) }

  describe "#resolve" do
    it "prefers the project credential over the chatting user's active repo token" do
      create(
        :github_token,
        account: account,
        created_by: user,
        name: "User Token",
        accessible_repositories: [ { "id" => project.github_id, "full_name" => project.full_name } ]
      )
      allow(project).to receive(:client).and_return(project_github_client)

      resolved = described_class.new(project:, user:, session:).resolve

      expect(resolved.client).to be(project_github_client)
      expect(resolved.credential).to eq(project.github_credential)
      expect(resolved.identity).to eq("project-token:#{project.github_token.name}")
    end

    it "returns the opaque GitHub App credential for app-backed projects, still preferred over a user token" do
      project = create(:project, :with_github_installation, account: account)
      create(
        :github_token,
        account: account,
        created_by: user,
        name: "User Token",
        accessible_repositories: [ { "id" => project.github_id, "full_name" => project.full_name } ]
      )
      allow(project).to receive_messages(
        github_credential: "ghs_app_token",
        client: project_github_client
      )

      resolved = described_class.new(project:, user:, session:).resolve

      expect(resolved.client).to be(project_github_client)
      expect(resolved.credential).to eq("ghs_app_token")
      expect(resolved.identity).to eq("github-app:#{project.github_installation.github_installation_id}")
    end

    it "falls back to the chatting user's active repo token when the project has no usable credential" do
      allow(project).to receive_messages(github_credential: nil, client: nil)
      user_token = create(
        :github_token,
        account: account,
        created_by: user,
        name: "User Token",
        accessible_repositories: [ { "id" => project.github_id, "full_name" => project.full_name } ]
      )
      allow(GithubClient).to receive(:new) do |token:, **|
        token == user_token.token ? user_github_client : project_github_client
      end

      resolved = described_class.new(project:, user:, session:).resolve

      expect(resolved.client).to eq(user_github_client)
      expect(resolved.credential).to eq(user_token.token)
      expect(resolved.identity).to eq("user-token:User Token")
    end

    it "falls back to the user token when the project credential cannot access the repo (no client)" do
      allow(project).to receive_messages(github_credential: "stale_token", client: nil)
      user_token = create(
        :github_token,
        account: account,
        created_by: user,
        name: "User Token",
        accessible_repositories: [ { "id" => project.github_id, "full_name" => project.full_name } ]
      )
      allow(GithubClient).to receive(:new) do |token:, **|
        token == user_token.token ? user_github_client : project_github_client
      end

      resolved = described_class.new(project:, user:, session:).resolve

      expect(resolved.client).to eq(user_github_client)
      expect(resolved.identity).to eq("user-token:User Token")
    end

    it "raises when neither the project nor the user has a usable credential" do
      allow(project).to receive_messages(github_credential: nil, client: nil)

      expect { described_class.new(project:, user:, session:).resolve }
        .to raise_error(ArgumentError, "Project has no GitHub credentials configured")
    end
  end
end
