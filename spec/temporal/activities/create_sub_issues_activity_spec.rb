# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::CreateSubIssuesActivity do
  let(:activity) { described_class.new }
  let(:project) { create(:project) }
  let(:parent_issue) { create(:issue, project: project, github_number: 100) }
  let(:github_client) { instance_double(GithubClient) }

  let(:sub_tasks) do
    [
      { title: "Implement authentication", body: "Add JWT-based auth to the API" },
      { title: "Add database migrations", body: "Create users and sessions tables" }
    ]
  end

  def gh_issue_response(number:, id:, title:, body:)
    Struct.new(:number, :id, :title, :body, :state, :user, :labels, :created_at, :updated_at, :html_url).new(
      number, id, title, body, "open",
      Struct.new(:login).new("paid-bot"),
      [], Time.current, Time.current,
      "https://github.com/#{project.full_name}/issues/#{number}"
    )
  end

  before do
    allow(GithubClient).to receive(:new).and_return(github_client)
    allow(github_client).to receive(:create_issue).and_return(
      gh_issue_response(number: 101, id: 200_001, title: "Implement authentication", body: "body1"),
      gh_issue_response(number: 102, id: 200_002, title: "Add database migrations", body: "body2")
    )
  end

  describe "#execute" do
    it "creates GitHub issues for each sub-task" do
      expect(github_client).to receive(:create_issue).twice

      activity.execute(project_id: project.id, parent_issue_id: parent_issue.id, sub_tasks: sub_tasks)
    end

    it "includes parent reference in sub-issue body" do
      expect(github_client).to receive(:create_issue).with(
        project.full_name,
        hash_including(body: a_string_including("Sub-issue of #100"))
      ).twice

      activity.execute(project_id: project.id, parent_issue_id: parent_issue.id, sub_tasks: sub_tasks)
    end

    it "includes task body in sub-issue body" do
      expect(github_client).to receive(:create_issue).with(
        project.full_name,
        hash_including(body: a_string_including("Add JWT-based auth"))
      ).ordered

      expect(github_client).to receive(:create_issue).with(
        project.full_name,
        hash_including(body: a_string_including("Create users and sessions"))
      ).ordered

      activity.execute(project_id: project.id, parent_issue_id: parent_issue.id, sub_tasks: sub_tasks)
    end

    it "syncs created issues to the local database" do
      parent_issue # ensure parent is created before counting
      expect {
        activity.execute(project_id: project.id, parent_issue_id: parent_issue.id, sub_tasks: sub_tasks)
      }.to change(Issue, :count).by(2)
    end

    it "sets parent-child relationships on synced issues" do
      activity.execute(project_id: project.id, parent_issue_id: parent_issue.id, sub_tasks: sub_tasks)

      children = parent_issue.sub_issues.reload
      expect(children.size).to eq(2)
      expect(children.map(&:github_number)).to contain_exactly(101, 102)
    end

    it "returns created issue details" do
      result = activity.execute(project_id: project.id, parent_issue_id: parent_issue.id, sub_tasks: sub_tasks)

      expect(result[:parent_issue_id]).to eq(parent_issue.id)
      expect(result[:created_issues].size).to eq(2)
      expect(result[:created_issues].first[:github_number]).to eq(101)
      expect(result[:created_issues].last[:github_number]).to eq(102)
    end

    context "when automation_on_label_enabled is true" do
      before { project.update!(automation_on_label_enabled: true) }

      it "adds the automation label for automatic pickup" do
        expect(github_client).to receive(:create_issue).with(
          project.full_name,
          hash_including(labels: a_collection_including(project.automation_label_name))
        ).twice

        activity.execute(project_id: project.id, parent_issue_id: parent_issue.id, sub_tasks: sub_tasks)
      end
    end

    context "when automation_on_label_enabled is false" do
      before { project.update!(automation_on_label_enabled: false) }

      it "does not add the automation label" do
        expect(github_client).to receive(:create_issue).with(
          project.full_name,
          hash_including(labels: satisfy { |l| !l.include?(project.automation_label_name) })
        ).twice

        activity.execute(project_id: project.id, parent_issue_id: parent_issue.id, sub_tasks: sub_tasks)
      end
    end

    context "when auto_add_labels_enabled is true" do
      before { project.update!(auto_add_labels_enabled: true) }

      it "adds the generated label" do
        expect(github_client).to receive(:create_issue).with(
          project.full_name,
          hash_including(labels: a_collection_including(project.generated_label_name))
        ).twice

        activity.execute(project_id: project.id, parent_issue_id: parent_issue.id, sub_tasks: sub_tasks)
      end
    end

    context "when auto_add_labels_enabled is false" do
      before { project.update!(auto_add_labels_enabled: false) }

      it "does not add the generated label" do
        expect(github_client).to receive(:create_issue).with(
          project.full_name,
          hash_including(labels: satisfy { |l| !l.include?(project.generated_label_name) })
        ).twice

        activity.execute(project_id: project.id, parent_issue_id: parent_issue.id, sub_tasks: sub_tasks)
      end
    end

    context "with empty sub_tasks" do
      it "returns empty created_issues array" do
        result = activity.execute(project_id: project.id, parent_issue_id: parent_issue.id, sub_tasks: [])

        expect(result[:created_issues]).to eq([])
      end

      it "does not call the GitHub API" do
        expect(github_client).not_to receive(:create_issue)

        activity.execute(project_id: project.id, parent_issue_id: parent_issue.id, sub_tasks: [])
      end
    end

    it "raises ActiveRecord::RecordNotFound for invalid project_id" do
      expect {
        activity.execute(project_id: -1, parent_issue_id: parent_issue.id, sub_tasks: sub_tasks)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises ActiveRecord::RecordNotFound for invalid parent_issue_id" do
      expect {
        activity.execute(project_id: project.id, parent_issue_id: -1, sub_tasks: sub_tasks)
      }.to raise_error(ActiveRecord::RecordNotFound)
    end

    context "when sync_issue_record fails" do
      it "continues creating remaining issues and returns nil issue_id" do
        parent_issue # ensure created before stubbing

        allow(Project).to receive(:find).with(project.id).and_return(project)
        issues_relation = project.issues
        allow(project).to receive(:issues).and_return(issues_relation)

        bad_issue = Issue.new
        allow(bad_issue).to receive(:update!).and_raise(StandardError, "DB error")
        allow(issues_relation).to receive(:find_or_initialize_by).and_return(bad_issue)

        result = activity.execute(project_id: project.id, parent_issue_id: parent_issue.id, sub_tasks: sub_tasks)

        expect(result[:created_issues].size).to eq(2)
        expect(result[:created_issues].map { |i| i[:issue_id] }).to all(be_nil)
      end
    end
  end
end
