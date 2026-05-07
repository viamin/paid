# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Screenshots::RepoConfig do
  describe ".call" do
    let(:github_client) { instance_double(GithubClient) }
    let(:github_token) { instance_double(GithubToken, client: github_client) }
    let(:project) do
      instance_double(
        Project,
        github_token: github_token,
        full_name: "acme/widgets"
      )
    end

    it "returns empty config when the repository config does not exist" do
      allow(github_client).to receive(:file_content)
        .and_raise(GithubClient::NotFoundError.new("Not Found"))

      result = described_class.call(project: project, path: ".paid/screenshots.yml")

      expect(result.config).to eq({})
      expect(result.content).to be_nil
      expect(result.error).to be_nil
    end
  end
end
