# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::RepoReadClientResolver do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:project) { create(:project, account: account) }
  let(:project_github_client) { instance_double(GithubClient) }
  let(:user_github_client) { instance_double(GithubClient) }

  describe "#resolve" do
    it "prefers the chatting user's active repo token over the project credential" do
      user_token = create(
        :github_token,
        account: account,
        created_by: user,
        name: "User Token",
        accessible_repositories: [ { "id" => project.github_id, "full_name" => project.full_name } ]
      )
      allow(project).to receive(:client).and_return(project_github_client)
      allow(GithubClient).to receive(:new) do |token:, **|
        token == user_token.token ? user_github_client : project_github_client
      end

      resolved = described_class.new(project:, user:, session:).resolve

      expect(resolved.client).to eq(user_github_client)
      expect(resolved.identity).to eq("user-token:User Token")
      expect(project).not_to have_received(:client)
    end

    it "falls back to the project credential when the user token does not cover the repo" do
      create(
        :github_token,
        account: account,
        created_by: user,
        name: "Other Repo Token",
        accessible_repositories: [ { "id" => 999, "full_name" => "other/repo" } ]
      )
      allow(project).to receive(:client).and_return(project_github_client)

      resolved = described_class.new(project:, user:, session:).resolve

      expect(resolved.client).to be(project_github_client)
      expect(resolved.identity).to eq("project-token:#{project.github_token.name}")
    end
  end
end
