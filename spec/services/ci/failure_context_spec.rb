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
end
