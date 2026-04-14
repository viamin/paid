# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::UpsertFromGithub do
  describe ".call" do
    let(:project) { create(:project) }
    let(:github_issue) do
      OpenStruct.new(
        id: 1234,
        number: 42,
        title: "Sync me",
        body: "GitHub body",
        state: "open",
        labels: [ OpenStruct.new(name: "paid-generated"), "P1" ],
        pull_request: OpenStruct.new(html_url: "https://github.com/test/repo/pull/42"),
        user: OpenStruct.new(login: "viamin"),
        created_at: Time.zone.parse("2026-04-14 00:00:00 UTC"),
        updated_at: Time.zone.parse("2026-04-14 00:01:00 UTC")
      )
    end

    it "creates a local issue row using the GitHub issue-shaped payload" do
      issue = described_class.call(project: project, github_issue: github_issue)

      expect(issue).to have_attributes(
        project_id: project.id,
        github_issue_id: 1234,
        github_number: 42,
        title: "Sync me",
        body: "GitHub body",
        github_state: "open",
        github_creator_login: "viamin",
        is_pull_request: true,
        labels: [ "paid-generated", "P1" ]
      )
    end

    it "allows callers to override the stored body" do
      issue = described_class.call(project: project, github_issue: github_issue, body: nil)

      expect(issue.body).to be_nil
    end

    it "updates an existing row instead of creating a duplicate" do
      existing = create(:issue, :pull_request, project: project, github_issue_id: 1234,
        github_number: 40, title: "Old", labels: [])

      issue = described_class.call(project: project, github_issue: github_issue)

      expect(issue.id).to eq(existing.id)
      expect(project.issues.where(github_issue_id: 1234).count).to eq(1)
      expect(issue.github_number).to eq(42)
    end
  end
end
