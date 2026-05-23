# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe DependencyBackfillJob do
  let(:project) { create(:project) }
  let(:account) { project.account }
  let(:github_client) { instance_double(GithubClient) }

  around do |example|
    TenantContext.with(account) { example.run }
  end

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

  def github_issue(number, state: "closed")
    OpenStruct.new(
      id: 99_000 + number,
      number: number,
      title: "Issue #{number}",
      body: "body",
      state: state,
      labels: [],
      pull_request: nil,
      user: OpenStruct.new(login: "dev"),
      created_at: 2.days.ago,
      updated_at: 5.minutes.ago
    )
  end

  describe "#perform" do
    it "fetches missing issues from GitHub and upserts them" do
      allow(github_client).to receive(:issue).with(project.full_name, 42).and_return(github_issue(42))

      expect {
        described_class.perform_now(project.id, [ 42 ])
      }.to change { project.issues.where(github_number: 42).count }.by(1)

      issue = project.issues.find_by(github_number: 42)
      expect(issue.github_state).to eq("closed")
    end

    it "skips issues that already exist in the database" do
      create(:issue, project: project, github_number: 42, github_state: "closed")

      expect(github_client).not_to receive(:issue)

      described_class.perform_now(project.id, [ 42 ])
    end

    it "handles GithubClient::NotFoundError gracefully" do
      allow(github_client).to receive(:issue).with(project.full_name, 999)
        .and_raise(GithubClient::NotFoundError, "Not Found")

      expect {
        described_class.perform_now(project.id, [ 999 ])
      }.not_to raise_error
    end

    it "does nothing when the project does not exist" do
      expect {
        described_class.perform_now(-1, [ 42 ])
      }.not_to raise_error
    end

    it "does not reevaluate dependents when no issues were backfilled" do
      create(:issue, project: project, github_number: 42, github_state: "closed")

      expect(Issues::EnqueueEligible).not_to receive(:call)

      described_class.perform_now(project.id, [ 42 ])
    end
  end
end
