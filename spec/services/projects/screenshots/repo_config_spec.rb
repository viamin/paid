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

    it "treats blocked test network requests as missing repo config" do
      blocked_request = WebMock::RequestSignature.new(
        :get,
        "https://api.github.com/repos/acme/widgets/contents/.paid/screenshots.yml"
      )
      allow(github_client).to receive(:file_content)
        .and_raise(WebMock::NetConnectNotAllowedError.new(blocked_request))

      result = described_class.call(project: project, path: ".paid/screenshots.yml")

      expect(result.config).to eq({
        "services" => [],
        "setup" => []
      })
      expect(result.content).to be_nil
      expect(result.error).to be_nil
    end
  end
end
