# frozen_string_literal: true

require "rails_helper"
require "ostruct"

# @spec PROJECT-CREATION-002
# @spec PROJECT-CREATION-003
# @spec PROJECT-CREATION-004
# @spec PROJECT-CREATION-005
# @spec PROJECT-CREATION-008
RSpec.describe Projects::CreateBlank do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:github_token) { create(:github_token, account: account) }

  let(:client) do
    instance_double(GithubClient).tap do |double|
      allow(double).to receive_messages(
        authenticated_login: "octocat",
        organizations: [ OpenStruct.new(login: "acme-org") ],
        labels: [],
        create_label: nil,
        create_issue: OpenStruct.new(html_url: "https://github.com/octocat/fresh-start/issues/1")
      )
    end
  end

  before do
    allow(github_token).to receive(:client).and_return(client)
  end

  def repo_response(id: 987_654, name: "fresh-start", owner_login: "octocat")
    OpenStruct.new(
      id: id,
      name: name,
      owner: OpenStruct.new(login: owner_login),
      default_branch: "main",
      language: nil
    )
  end

  describe ".call with a GitHub token" do
    it "creates the repository under the token's user and persists the project" do
      allow(client).to receive(:create_repository).and_return(repo_response)

      result = described_class.call(
        account: account,
        user: user,
        github_token: github_token,
        repo_name: "fresh-start"
      )

      expect(client).to have_received(:create_repository)
        .with("fresh-start", organization: nil, private: true, description: nil)

      project = result.project
      expect(project).to be_persisted
      expect(project.account).to eq(account)
      expect(project.owner).to eq("octocat")
      expect(project.repo).to eq("fresh-start")
      expect(project.github_id).to eq(987_654)
      expect(project.default_branch).to eq("main")
      expect(project.created_by).to eq(user)
      expect(project.github_token).to eq(github_token)
      expect(project.allowed_github_usernames).to eq([ "octocat" ])
    end

    it "marks the project as blank origin with pending setup" do
      allow(client).to receive(:create_repository).and_return(repo_response)

      project = described_class.call(
        account: account, user: user, github_token: github_token, repo_name: "fresh-start"
      ).project

      expect(project.creation_origin).to eq("blank")
      expect(project.setup_status).to eq("pending")
      expect(project).to be_setup_pending
      expect(project).to be_blank_origin
    end

    it "creates the repository under an organization the token belongs to" do
      allow(client).to receive(:create_repository).and_return(repo_response(owner_login: "acme-org"))

      project = described_class.call(
        account: account, user: user, github_token: github_token,
        repo_name: "fresh-start", owner: "ACME-Org"
      ).project

      expect(client).to have_received(:create_repository)
        .with("fresh-start", organization: "acme-org", private: true, description: nil)
      expect(project.owner).to eq("acme-org")
    end

    it "passes through visibility and description options" do
      allow(client).to receive(:create_repository).and_return(repo_response)

      described_class.call(
        account: account, user: user, github_token: github_token,
        repo_name: "fresh-start", description: "A fresh start", private: false
      )

      expect(client).to have_received(:create_repository)
        .with("fresh-start", organization: nil, private: false, description: "A fresh start")
    end

    it "creates a bootstrap issue carrying the setup questionnaire" do
      allow(client).to receive(:create_repository).and_return(repo_response)

      result = described_class.call(
        account: account, user: user, github_token: github_token, repo_name: "fresh-start"
      )

      expect(client).to have_received(:create_issue).with(
        "octocat/fresh-start",
        title: a_string_including("Bootstrap"),
        body: a_string_including("grill", "Language and framework", "CI"),
        labels: [ "needs-manual-setup" ]
      )
      expect(result.bootstrap_issue_url).to eq("https://github.com/octocat/fresh-start/issues/1")
    end

    it "does not fail project creation when the bootstrap issue cannot be created" do
      allow(client).to receive(:create_repository).and_return(repo_response)
      allow(client).to receive(:create_issue).and_raise(GithubClient::ApiError.new("creation not allowed"))

      result = described_class.call(
        account: account, user: user, github_token: github_token, repo_name: "fresh-start"
      )

      expect(result.project).to be_persisted
      expect(result.bootstrap_issue_url).to be_nil
    end

    it "applies standard labels to the created repository" do
      allow(client).to receive(:create_repository).and_return(repo_response)

      described_class.call(
        account: account, user: user, github_token: github_token, repo_name: "fresh-start"
      )

      expect(client).to have_received(:labels).with("octocat/fresh-start")
      expect(client).to have_received(:create_label).at_least(:once)
    end
  end

  describe "credential validation" do
    it "rejects creation when no credential is selected" do
      expect {
        described_class.call(account: account, user: user, repo_name: "fresh-start")
      }.to raise_error(Projects::CreateBlank::ValidationError, /exactly one GitHub credential/)
    end

    it "rejects creation when both credentials are selected" do
      installation = create(:github_installation, account: account)
      expect {
        described_class.call(
          account: account, user: user,
          github_token: github_token, github_installation: installation,
          repo_name: "fresh-start"
        )
      }.to raise_error(Projects::CreateBlank::ValidationError, /exactly one GitHub credential/)
    end
  end

  describe "owner authorization" do
    it "rejects an owner that is neither the token user nor one of its organizations" do
      expect {
        described_class.call(
          account: account, user: user, github_token: github_token,
          repo_name: "fresh-start", owner: "someone-else"
        )
      }.to raise_error(Projects::CreateBlank::ValidationError, /not the token's user/)
    end

    it "creates nothing on GitHub when the owner is unauthorized" do
      allow(client).to receive(:create_repository)

      expect {
        described_class.call(
          account: account, user: user, github_token: github_token,
          repo_name: "fresh-start", owner: "someone-else"
        )
      }.to raise_error(Projects::CreateBlank::ValidationError)

      expect(client).not_to have_received(:create_repository)
    end
  end

  describe "repository name validation" do
    it "rejects names with invalid characters" do
      expect {
        described_class.call(
          account: account, user: user, github_token: github_token, repo_name: "not valid!"
        )
      }.to raise_error(Projects::CreateBlank::ValidationError, /may only contain/)
    end

    it "rejects a blank name" do
      expect {
        described_class.call(account: account, user: user, github_token: github_token, repo_name: "  ")
      }.to raise_error(Projects::CreateBlank::ValidationError, /may only contain/)
    end

    it "rejects an owner/repo pair that already exists as a project in the account" do
      create(:project, account: account, owner: "OCTOCAT", repo: "Fresh-Start")
      allow(client).to receive(:create_repository)

      expect {
        described_class.call(
          account: account, user: user, github_token: github_token, repo_name: "fresh-start"
        )
      }.to raise_error(Projects::CreateBlank::ValidationError, /already exists/)

      expect(client).not_to have_received(:create_repository)
    end
  end

  describe "with a GitHub App installation" do
    let(:installation) { create(:github_installation, account: account, account_login: "acme-org") }

    before do
      allow(Github::AppInstallation).to receive(:provisioning_token_for)
        .with(installation_id: installation.github_installation_id)
        .and_return("ghs_installtoken_#{SecureRandom.alphanumeric(30)}")
      allow(Github::AppInstallation).to receive(:token_for)
        .with(installation_id: installation.github_installation_id, repo_full_name: "acme-org/fresh-start")
        .and_return("ghs_repotoken_#{SecureRandom.alphanumeric(30)}")
      allow(GithubClient).to receive(:new).and_return(client)
    end

    it "creates the repository under the installation account" do
      allow(client).to receive(:create_repository).and_return(repo_response(owner_login: "acme-org"))

      project = described_class.call(
        account: account, user: user, github_installation: installation, repo_name: "fresh-start"
      ).project

      expect(client).to have_received(:create_repository)
        .with("fresh-start", organization: "acme-org", private: true, description: nil)
      expect(project.github_installation).to eq(installation)
      expect(project.owner).to eq("acme-org")
    end

    it "creates under the authenticated user for a user installation" do
      installation.update!(target_type: "User")
      allow(client).to receive(:create_repository).and_return(repo_response(owner_login: "acme-org"))

      described_class.call(
        account: account, user: user, github_installation: installation, repo_name: "fresh-start"
      )

      expect(client).to have_received(:create_repository)
        .with("fresh-start", organization: nil, private: true, description: nil)
    end

    it "rejects an owner that differs from the installation account" do
      expect {
        described_class.call(
          account: account, user: user, github_installation: installation,
          repo_name: "fresh-start", owner: "octocat"
        )
      }.to raise_error(Projects::CreateBlank::ValidationError, /can only create repositories under acme-org/)
    end
  end

  describe "GitHub API failures" do
    it "propagates authentication errors without persisting a project" do
      allow(client).to receive(:create_repository).and_raise(GithubClient::AuthenticationError.new("bad token"))

      expect {
        described_class.call(account: account, user: user, github_token: github_token, repo_name: "fresh-start")
      }.to raise_error(GithubClient::AuthenticationError)

      expect(account.projects.count).to eq(0)
    end

    it "propagates name-collision API errors" do
      allow(client).to receive(:create_repository).and_raise(GithubClient::ApiError.new("name already exists on this account", status: 422))

      expect {
        described_class.call(account: account, user: user, github_token: github_token, repo_name: "fresh-start")
      }.to raise_error(GithubClient::ApiError)
    end
  end
end
