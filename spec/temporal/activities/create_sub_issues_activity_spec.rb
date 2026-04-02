# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CreateSubIssuesActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:parent_issue) { create(:issue, project: project, title: "Parent feature") }
  let(:github_client) { instance_double(GithubClient) }
  let(:issue_counter) { [ 0 ] }

  let(:tasks) do
    [
      { title: "Add migration", description: "Create table for X", dependencies: [], parallel_group: 0 },
      { title: "Add model", description: "Create model for X", dependencies: [ 0 ], parallel_group: 1 }
    ]
  end

  def make_gh_issue(title, number)
    Struct.new(:id, :number, :title, :body, :state, :user, :labels, :created_at, :updated_at, :html_url).new(
      900_000 + number,
      number,
      title,
      "Issue body",
      "open",
      Struct.new(:login).new("paid-bot"),
      [],
      Time.current,
      Time.current,
      "https://github.com/o/r/issues/#{number}"
    )
  end

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:create_issue) do |_repo, title:, **_opts|
      issue_counter[0] += 1
      make_gh_issue(title, 100 + issue_counter[0])
    end
  end

  describe "#execute" do
    it "creates sub-issues for each task" do
      result = activity.execute(
        project_id: project.id,
        parent_issue_id: parent_issue.id,
        tasks: tasks
      )

      expect(result[:sub_issue_ids].size).to eq(2)
      expect(github_client).to have_received(:create_issue).twice
    end

    it "links sub-issues to the parent issue" do
      activity.execute(
        project_id: project.id,
        parent_issue_id: parent_issue.id,
        tasks: tasks
      )

      sub_issues = parent_issue.sub_issues.reload
      expect(sub_issues.size).to eq(2)
      expect(sub_issues.map(&:title)).to contain_exactly("Add migration", "Add model")
    end

    it "creates dependency records between sub-issues" do
      activity.execute(
        project_id: project.id,
        parent_issue_id: parent_issue.id,
        tasks: tasks
      )

      sub_issues = parent_issue.sub_issues.order(:id).to_a
      model_issue = sub_issues.find { |i| i.title == "Add model" }
      migration_issue = sub_issues.find { |i| i.title == "Add migration" }

      expect(model_issue.dependencies).to include(migration_issue)
    end

    it "returns empty array when tasks are empty" do
      result = activity.execute(
        project_id: project.id,
        parent_issue_id: parent_issue.id,
        tasks: []
      )

      expect(result[:sub_issue_ids]).to eq([])
    end

    context "when a single sub-issue creation fails" do
      before do
        call_count = 0
        allow(github_client).to receive(:create_issue) do |_repo, **_opts|
          call_count += 1
          raise StandardError, "API error" if call_count == 1
          make_gh_issue("Task 2", 102)
        end
      end

      it "continues creating remaining sub-issues" do
        result = activity.execute(
          project_id: project.id,
          parent_issue_id: parent_issue.id,
          tasks: tasks
        )

        # First fails (nil), second succeeds
        expect(result[:sub_issue_ids].compact.size).to eq(1)
      end
    end
  end
end
