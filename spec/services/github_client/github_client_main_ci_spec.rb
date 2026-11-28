# frozen_string_literal: true

require "rails_helper"

RSpec.describe GithubClient do
  let(:client) { described_class.new(token: "main-ci-test-token") }
  let(:sha) { "a" * 40 }

  # @spec MAIN-CI-001 MAIN-CI-006
  it "reads the default branch from the repository and binds workflow proof to event and SHA" do
    stub_request(:get, "https://api.github.com/repos/o/r").to_return(body: { default_branch: "trunk" }.to_json,
      headers: { "Content-Type" => "application/json" })
    stub_request(:get, "https://api.github.com/repos/o/r/git/refs/heads/trunk").to_return(body: { object: { sha: sha } }.to_json,
      headers: { "Content-Type" => "application/json" })
    request = stub_request(:get, "https://api.github.com/repos/o/r/actions/runs")
      .with(query: { head_sha: sha, branch: "trunk", event: "push", per_page: 100 })
      .to_return(body: { total_count: 1, workflow_runs: [ { id: 1, run_attempt: 2, path: ".github/workflows/ci.yml",
        event: "push", head_branch: "trunk", head_sha: sha, status: "completed", conclusion: "success" } ] }.to_json,
        headers: { "Content-Type" => "application/json" })
    expect(client.default_branch_head("o/r")).to eq(branch: "trunk", sha: sha)
    expect(client.full_verification_runs("o/r", sha: sha, branch: "trunk").first).to include(run_attempt: 2, head_sha: sha)
    expect(request).to have_been_requested
  end

  # @spec MAIN-CI-002
  it "rejects truncated workflow coverage" do
    stub_request(:get, "https://api.github.com/repos/o/r/actions/runs")
      .with(query: { head_sha: sha, branch: "main", event: "push", per_page: 100 })
      .to_return(body: { total_count: 101, workflow_runs: [] }.to_json, headers: { "Content-Type" => "application/json" })
    expect { client.full_verification_runs("o/r", sha: sha, branch: "main") }.to raise_error(GithubClient::Error, /truncated/)
  end

  # @spec MAIN-CI-001
  it "uses bounded branch history only for failure discovery" do
    request = stub_request(:get, "https://api.github.com/repos/o/r/actions/runs")
      .with(query: { branch: "main", event: "push", per_page: 100 })
      .to_return(body: { total_count: 101, workflow_runs: [] }.to_json, headers: { "Content-Type" => "application/json" })
    expect(client.full_verification_runs("o/r", branch: "main")).to eq([])
    expect(request).to have_been_requested
  end
end
