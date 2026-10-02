# frozen_string_literal: true

require "rails_helper"

RSpec.describe Projects::Screenshots::CommitConfig, :no_db do
  let(:github_client) { instance_double(GithubClient) }
  let(:project) { Struct.new(:id, :full_name, :default_branch, :client).new(7, "owner/repo", "main", github_client) }
  let(:base_ref) { Struct.new(:object).new(Struct.new(:sha).new("base-sha")) }
  let(:pull_request) { Struct.new(:html_url).new("https://github.com/owner/repo/pull/1") }

  before do
    allow(github_client).to receive(:ref).with("owner/repo", "heads/main").and_return(base_ref)
    allow(github_client).to receive(:create_ref)
    allow(github_client).to receive(:create_pull_request).and_return(pull_request)
  end

  # @spec GITHUB-SYNC-017
  it "uses the project's GitHub client when creating repository configuration" do
    allow(github_client).to receive(:contents)
      .with("owner/repo", path: ".github/paid-screenshots.yml", ref: "main")
      .and_raise(GithubClient::NotFoundError)
    allow(github_client).to receive(:create_contents)

    result = described_class.call(project:, config_path: ".github/paid-screenshots.yml", content: "enabled: true\n")

    expect(github_client).to have_received(:create_ref).with(
      "owner/repo", a_string_starting_with("refs/heads/paid/screenshots-config-7-"), "base-sha"
    )
    expect(github_client).to have_received(:create_contents).with(
      "owner/repo", ".github/paid-screenshots.yml", "Add screenshot configuration for Paid", "enabled: true\n",
      branch: a_string_starting_with("paid/screenshots-config-7-")
    )
    expect(result.pull_request_url).to eq("https://github.com/owner/repo/pull/1")
  end

  # @spec GITHUB-SYNC-017
  it "uses the project's GitHub client when updating repository configuration" do
    existing_file = Struct.new(:sha).new("existing-sha")
    allow(github_client).to receive(:contents).and_return(existing_file)
    allow(github_client).to receive(:update_contents)

    described_class.call(project:, config_path: ".github/paid-screenshots.yml", content: "enabled: false\n")

    expect(github_client).to have_received(:update_contents).with(
      "owner/repo", ".github/paid-screenshots.yml", "Add screenshot configuration for Paid", "existing-sha", "enabled: false\n",
      branch: a_string_starting_with("paid/screenshots-config-7-")
    )
  end
end
