# frozen_string_literal: true

require "rails_helper"

RSpec.describe "GithubInstallations" do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }

  describe "GET /github_installations/:id/repositories" do
    before { sign_in user }

    it "returns normalized repositories for the installation" do
      installation = create(
        :github_installation,
        account: account,
        accessible_repositories: [
          { "id" => 123, "full_name" => "acme/widgets", "private" => true, "default_branch" => "trunk" }
        ]
      )

      get repositories_github_installation_path(installation)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq([
        {
          "id" => 123,
          "full_name" => "acme/widgets",
          "name" => "widgets",
          "owner" => "acme",
          "default_branch" => "trunk",
          "private" => true
        }
      ])
    end

    it "filters out repositories already linked to the current account" do
      installation = create(
        :github_installation,
        account: account,
        accessible_repositories: [
          { "id" => 123, "full_name" => "acme/widgets" },
          { "id" => 456, "full_name" => "acme/gadgets" }
        ]
      )
      create(:project, account: account, created_by: user, github_id: 123)

      get repositories_github_installation_path(installation)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.map { |repo| repo.fetch("id") }).to eq([ 456 ])
    end
  end
end
