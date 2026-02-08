# frozen_string_literal: true

require "rails_helper"
require "ostruct"

RSpec.describe Activities::FetchIssuesActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project, label_mappings: { "build" => "paid-build", "plan" => "paid-plan" }) }
  let(:github_client) { instance_double(GithubClient) }

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
  end

  describe "#execute" do
    context "when issues are found" do
      let(:github_issues) do
        [
          OpenStruct.new(
            id: 1001,
            number: 1,
            title: "Build this feature",
            body: "Please build it",
            state: "open",
            labels: [ OpenStruct.new(name: "paid-build") ],
            created_at: 2.days.ago,
            updated_at: 1.day.ago
          ),
          OpenStruct.new(
            id: 1002,
            number: 2,
            title: "Plan this feature",
            body: "Please plan it",
            state: "open",
            labels: [ OpenStruct.new(name: "paid-plan"), OpenStruct.new(name: "enhancement") ],
            created_at: 1.day.ago,
            updated_at: Time.current
          )
        ]
      end

      before do
        allow(github_client).to receive(:issues).and_return(github_issues)
      end

      it "syncs issues to the database" do
        result = activity.execute(project_id: project.id)

        expect(project.issues.count).to eq(2)
        expect(result[:issues].size).to eq(2)
        expect(result[:project_id]).to eq(project.id)
      end

      it "stores labels as string arrays" do
        activity.execute(project_id: project.id)

        issue = project.issues.find_by(github_issue_id: 1002)
        expect(issue.labels).to contain_exactly("paid-plan", "enhancement")
      end

      it "updates existing issues on re-fetch" do
        create(:issue, project: project, github_issue_id: 1001, github_number: 1, title: "Old title")

        activity.execute(project_id: project.id)

        issue = project.issues.find_by(github_issue_id: 1001)
        expect(issue.title).to eq("Build this feature")
        expect(project.issues.count).to eq(2)
      end
    end

    context "when no issues match" do
      before do
        allow(github_client).to receive(:issues).and_return([])
      end

      it "returns an empty issues array" do
        result = activity.execute(project_id: project.id)

        expect(result[:issues]).to eq([])
        expect(project.issues.count).to eq(0)
      end
    end

    context "when rate limited" do
      before do
        allow(github_client).to receive(:issues).and_raise(
          GithubClient::RateLimitError.new(Time.current + 3600)
        )
      end

      it "raises a Temporal application error" do
        expect {
          activity.execute(project_id: project.id)
        }.to raise_error(Temporalio::Error::ApplicationError) { |e|
          expect(e.type).to eq("RateLimit")
        }
      end
    end

    context "when project has no label mappings" do
      let(:project) { create(:project, label_mappings: {}) }

      before do
        allow(github_client).to receive(:issues).and_return([])
      end

      it "fetches with empty labels filter" do
        activity.execute(project_id: project.id)

        expect(github_client).to have_received(:issues).with(
          project.full_name,
          labels: [],
          state: "open",
          per_page: 100
        )
      end
    end
  end
end
