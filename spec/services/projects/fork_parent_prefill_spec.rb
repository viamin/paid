# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::ForkParentPrefill do
  let(:account) { create(:account) }
  let(:github_token) { create(:github_token, account: account) }
  let(:project) { create(:project, account: account, github_token: github_token, owner: "stenoai", repo: "stenoai") }

  describe ".call" do
    it "returns a :detected prefill when GitHub reports a fork parent" do # @spec PR-TARGET-009
      stub_request(:get, "https://api.github.com/repos/stenoai/stenoai")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { full_name: "stenoai/stenoai", parent: { full_name: "stenolabs/stenoai" } }.to_json
        )

      result = described_class.call(project)

      expect(result.detected?).to be(true)
      expect(result.upstream_full_name).to eq("stenolabs/stenoai")
      expect(result.reason).to eq("detected_from_fork_parent")
    end

    it "returns :unavailable with reason not_a_fork when no parent is present" do # @spec PR-TARGET-009
      stub_request(:get, "https://api.github.com/repos/stenoai/stenoai")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { full_name: "stenoai/stenoai", parent: nil }.to_json
        )

      result = described_class.call(project)

      expect(result.detected?).to be(false)
      expect(result.reason).to eq("not_a_fork")
    end

    it "returns :unavailable when the parent matches the project's own repository" do # @spec PR-TARGET-009
      stub_request(:get, "https://api.github.com/repos/stenoai/stenoai")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { full_name: "stenoai/stenoai", parent: { full_name: "stenoai/stenoai" } }.to_json
        )

      result = described_class.call(project)

      expect(result.detected?).to be(false)
      expect(result.reason).to eq("same_as_project")
    end

    it "returns :unavailable when the project has no GitHub credential" do # @spec PR-TARGET-009
      allow(project).to receive(:client).and_return(nil)

      result = described_class.call(project)

      expect(result.detected?).to be(false)
      expect(result.reason).to eq("no_github_credential")
    end

    it "returns :unavailable when the GitHub request fails" do # @spec PR-TARGET-009
      stub_request(:get, "https://api.github.com/repos/stenoai/stenoai").to_return(status: 500, body: "boom")

      result = described_class.call(project)

      expect(result.detected?).to be(false)
      expect(result.reason).to eq("github_request_failed")
    end

    it "returns :unavailable and logs when the credential is unauthorized" do # @spec PR-TARGET-009
      stub_request(:get, "https://api.github.com/repos/stenoai/stenoai").to_return(status: 401, body: "unauthorized")

      result = nil
      expect { result = described_class.call(project) }.not_to raise_error
      expect(result.detected?).to be(false)
      expect(result.reason).to eq("github_request_failed")
    end

    it "returns :unavailable and logs when the repository cannot be found" do # @spec PR-TARGET-009
      stub_request(:get, "https://api.github.com/repos/stenoai/stenoai").to_return(status: 404, body: "not found")

      result = nil
      expect { result = described_class.call(project) }.not_to raise_error
      expect(result.detected?).to be(false)
      expect(result.reason).to eq("github_request_failed")
    end

    it "lets unexpected, non-GitHub errors propagate so callers can log them" do # @spec PR-TARGET-009
      stub_request(:get, "https://api.github.com/repos/stenoai/stenoai").to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: "{}"
      )
      allow(project.client).to receive(:repository).and_raise(RuntimeError, "boom")

      expect { described_class.call(project) }.to raise_error(RuntimeError, "boom")
    end
  end
end
