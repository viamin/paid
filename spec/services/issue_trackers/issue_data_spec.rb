# frozen_string_literal: true

require "rails_helper"

RSpec.describe IssueTrackers::IssueData do
  it "creates with required fields" do
    issue = described_class.new(external_id: "123", title: "Test issue")

    expect(issue.external_id).to eq("123")
    expect(issue.title).to eq("Test issue")
    expect(issue.labels).to eq([])
    expect(issue.metadata).to eq({})
  end

  it "creates with all fields" do
    issue = described_class.new(
      external_id: "PROJ-42",
      title: "Fix bug",
      body: "Details here",
      status: "open",
      url: "https://jira.example.com/PROJ-42",
      labels: [ "bug" ],
      assignee: "dev@example.com",
      metadata: { priority: "high" }
    )

    expect(issue.external_id).to eq("PROJ-42")
    expect(issue.body).to eq("Details here")
    expect(issue.status).to eq("open")
    expect(issue.labels).to eq([ "bug" ])
    expect(issue.metadata).to eq({ priority: "high" })
  end

  it "is frozen" do
    issue = described_class.new(external_id: "1", title: "Test")

    expect(issue).to be_frozen
  end
end
