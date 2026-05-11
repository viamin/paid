# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ci::FailureContext do
  let(:github_client) { instance_double(GithubClient) }
  let(:repo) { "owner/repo" }

  before do
    allow(github_client).to receive(:check_run_log).and_return("")
  end

  it "keeps failed checks and extracts their logs" do
    checks = [
      { id: 1, name: "rspec", conclusion: "failure", output_text: "role \"root\" does not exist" },
      { id: 2, name: "rubocop", conclusion: "success", output_text: "ok" }
    ]

    context = described_class.call(repo: repo, checks: checks, github_client: github_client)

    expect(context).to be_failing
    expect(context.checks.map { |check| check[:name] }).to eq([ "rspec" ])
    expect(context.output).to include("## rspec")
    expect(context.output).to include("role \"root\" does not exist")
  end

  it "uses GitHub job logs when check output is empty" do
    check = { id: 1, name: "rspec", conclusion: "failure", output_text: "" }
    allow(github_client).to receive(:check_run_log)
      .with(repo, check)
      .and_return("database \"app_test\" does not exist")

    context = described_class.call(repo: repo, checks: [ check ], github_client: github_client)

    expect(context.output).to include("database \"app_test\" does not exist")
  end

  it "redacts secrets before extracting check output for prompts" do
    check = {
      id: 1,
      name: "rspec",
      conclusion: "failure",
      output_text: "api_key=#{'a' * 24}\nFailure: request failed"
    }
    token = "ghp_#{'b' * 36}"
    allow(github_client).to receive(:check_run_log)
      .with(repo, check)
      .and_return("GITHUB_TOKEN=#{token}")

    context = described_class.call(repo: repo, checks: [ check ], github_client: github_client)

    expect(context.output).to include("[REDACTED:api_key]")
    expect(context.output).to include("[REDACTED:github_token]")
    expect(context.output).not_to include("api_key=#{'a' * 24}")
    expect(context.output).not_to include(token)
  end

  it "does not treat pending checks as failing" do
    context = described_class.call(
      repo: repo,
      checks: [ { name: "rspec", conclusion: nil } ],
      github_client: github_client
    )

    expect(context).not_to be_failing
    expect(context.output).to eq("")
  end

  describe "failure type classification" do
    it "classifies database errors" do
      check = { id: 1, name: "rspec", conclusion: "failure", output_text: "ActiveRecord::NoDatabaseError: Database not found" }

      context = described_class.call(repo: repo, checks: [ check ], github_client: github_client)

      expect(context.failure_types).to include(:database)
    end

    it "classifies PG::ConnectionBad as database error" do
      check = { id: 1, name: "rspec", conclusion: "failure", output_text: "PG::ConnectionBad: FATAL: database does not exist" }

      context = described_class.call(repo: repo, checks: [ check ], github_client: github_client)

      expect(context.failure_types).to include(:database)
    end

    it "classifies dependency errors" do
      check = { id: 1, name: "build", conclusion: "failure", output_text: "Gem::LoadError: can't activate railties" }

      context = described_class.call(repo: repo, checks: [ check ], github_client: github_client)

      expect(context.failure_types).to include(:dependency)
    end

    it "classifies service errors" do
      check = { id: 1, name: "rspec", conclusion: "failure", output_text: "Connection refused - connect(2) for 127.0.0.1" }

      context = described_class.call(repo: repo, checks: [ check ], github_client: github_client)

      expect(context.failure_types).to include(:service)
    end

    it "classifies timeout errors" do
      check = { id: 1, name: "rspec", conclusion: "failure", output_text: "Net::ReadTimeout with API call" }

      context = described_class.call(repo: repo, checks: [ check ], github_client: github_client)

      expect(context.failure_types).to include(:timeout)
    end

    it "returns empty array when output has no matching patterns" do
      check = { id: 1, name: "rspec", conclusion: "failure", output_text: "Expected 2 to equal 3" }

      context = described_class.call(repo: repo, checks: [ check ], github_client: github_client)

      expect(context.failure_types).to eq([])
    end

    it "detects multiple failure types from the same output" do
      check = { id: 1, name: "rspec", conclusion: "failure", output_text: "ActiveRecord::NoDatabaseError and Connection refused" }

      context = described_class.call(repo: repo, checks: [ check ], github_client: github_client)

      expect(context.failure_types).to include(:database, :service)
    end
  end

  describe "workflow file fetching" do
    it "fetches workflow files for failed checks" do
      check = { id: 1, name: "rspec", conclusion: "failure", output_text: "failed", details_url: "https://github.com/owner/repo/actions/runs/12345/job/67890" }
      allow(github_client).to receive(:check_run_log).with(repo, check).and_return("")

      run_response = double(path: ".github/workflows/test.yml@main")
      allow(github_client).to receive(:actions_run)
        .with(repo, "12345")
        .and_return(run_response)

      workflow_yaml = "name: Test\non: push\njobs:\n  rspec:\n    runs-on: ubuntu-latest"
      allow(github_client).to receive(:file_content)
        .with(repo, path: ".github/workflows/test.yml", ref: "abc123")
        .and_return(workflow_yaml)

      context = described_class.call(repo: repo, checks: [ check ], github_client: github_client, ref: "abc123")

      expect(context.workflow_content).to include(".github/workflows/test.yml")
      expect(context.workflow_content).to include("name: Test")
      expect(context.workflow_content).to include("```yaml")
    end

    it "deduplicates workflow files across multiple checks" do
      check1 = { id: 1, name: "rspec", conclusion: "failure", output_text: "failed", details_url: "https://github.com/owner/repo/actions/runs/111/job/1" }
      check2 = { id: 2, name: "rubocop", conclusion: "failure", output_text: "failed", details_url: "https://github.com/owner/repo/actions/runs/111/job/2" }

      run_response = double(path: ".github/workflows/ci.yml@main")
      allow(github_client).to receive(:actions_run).with(repo, "111").and_return(run_response)
      allow(github_client).to receive_messages(check_run_log: "", file_content: "name: CI\non: push")

      _context = described_class.call(repo: repo, checks: [ check1, check2 ], github_client: github_client)

      expect(github_client).to have_received(:actions_run).once
      expect(github_client).to have_received(:file_content).once
    end

    it "strips the @ref suffix from the workflow path returned by the Actions API" do
      check = { id: 1, name: "rspec", conclusion: "failure", output_text: "failed", details_url: "https://github.com/owner/repo/actions/runs/999/job/1" }
      allow(github_client).to receive(:check_run_log).with(repo, check).and_return("")

      run_response = double(path: ".github/workflows/deploy.yml@refs/heads/feature")
      allow(github_client).to receive(:actions_run).with(repo, "999").and_return(run_response)
      allow(github_client).to receive(:file_content)
        .with(repo, path: ".github/workflows/deploy.yml", ref: nil)
        .and_return("name: Deploy")

      context = described_class.call(repo: repo, checks: [ check ], github_client: github_client)

      expect(context.workflow_content).to include(".github/workflows/deploy.yml")
      expect(context.workflow_content).to include("name: Deploy")
    end

    it "returns empty string when no details_url is available" do
      check = { id: 1, name: "rspec", conclusion: "failure", output_text: "failed" }
      allow(github_client).to receive(:check_run_log).with(repo, check).and_return("failed")

      context = described_class.call(repo: repo, checks: [ check ], github_client: github_client)

      expect(context.workflow_content).to eq("")
    end

    it "returns empty string when workflow fetch fails" do
      check = { id: 1, name: "rspec", conclusion: "failure", output_text: "failed", details_url: "https://github.com/owner/repo/actions/runs/12345/job/67890" }
      allow(github_client).to receive(:check_run_log).with(repo, check).and_return("")

      allow(github_client).to receive(:actions_run).and_raise(GithubClient::ApiError.new("not found"))

      context = described_class.call(repo: repo, checks: [ check ], github_client: github_client)

      expect(context.workflow_content).to eq("")
    end
  end
end
