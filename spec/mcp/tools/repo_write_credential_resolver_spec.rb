# frozen_string_literal: true

require "rails_helper"

# @spec CHAT-PR-PROPOSAL-001, CHAT-PR-PROPOSAL-002
RSpec.describe Tools::RepoWriteCredentialResolver do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:project) { create(:project, account: account) }
  let(:project_github_client) { instance_double(GithubClient) }
  let(:user_github_client) { instance_double(GithubClient) }

  describe "#resolve" do
    # @spec CHAT-PR-PROPOSAL-001, CHAT-PR-PROPOSAL-002
    it "prefers the chatting user's active repo token over the project credential" do
      user_token = create(
        :github_token,
        account: account,
        created_by: user,
        name: "User Token",
        accessible_repositories: [ { "id" => project.github_id, "full_name" => project.full_name } ]
      )
      allow(project).to receive_messages(client: project_github_client, github_credential: "project-token")
      allow(GithubClient).to receive(:new) do |token:, **|
        token == user_token.token ? user_github_client : project_github_client
      end

      resolved = described_class.new(project:, user:, session:).resolve

      expect(resolved.client).to eq(user_github_client)
      expect(resolved.credential).to eq(user_token.token)
      expect(resolved.identity).to eq("user-token:User Token")
      expect(resolved.from_user_token).to be(true)
      expect(project).not_to have_received(:client)
    end

    # @spec CHAT-PR-PROPOSAL-001
    it "falls back to the project credential when the user token does not cover the repo" do
      create(
        :github_token,
        account: account,
        created_by: user,
        name: "Other Repo Token",
        accessible_repositories: [ { "id" => 999, "full_name" => "other/repo" } ]
      )
      allow(project).to receive_messages(client: project_github_client, github_credential: "project-token")

      resolved = described_class.new(project:, user:, session:).resolve

      expect(resolved.client).to be(project_github_client)
      expect(resolved.credential).to eq("project-token")
      expect(resolved.identity).to eq("project-token:#{project.github_token.name}")
      expect(resolved.from_user_token).to be(false)
    end

    # @spec CHAT-PR-PROPOSAL-001
    it "raises the configured missing-credential error without constructing a project client" do
      allow(project).to receive_messages(github_credential: nil, client: project_github_client)

      expect {
        described_class.new(project:, user:, session:).resolve
      }.to raise_error(ArgumentError, "Project has no GitHub credentials configured")

      expect(project).not_to have_received(:client)
    end
  end
end
