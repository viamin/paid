# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::GetProjectIssues do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }
  let(:project) { create(:project, account: account) }

  describe "#call" do
    it "returns only issues by default" do
      issue = create(:issue, project: project, title: "Issue A")
      create(:issue, :pull_request, project: project, title: "PR A")

      result = tool.call(project_id: project.id)

      expect(result.map { |entry| entry[:id] }).to eq([ issue.id ])
    end

    it "filters by paid state" do
      matching = create(:issue, :failed, project: project)
      create(:issue, :completed, project: project)

      result = tool.call(project_id: project.id, state: "failed")

      expect(result.map { |entry| entry[:id] }).to eq([ matching.id ])
    end

    it "returns pull requests when requested" do
      pr = create(:issue, :pull_request, project: project)
      create(:issue, project: project)

      result = tool.call(project_id: project.id, is_pull_request: true)

      expect(result.map { |entry| entry[:id] }).to eq([ pr.id ])
    end

    it "clamps the limit" do
      older = create(:issue, project: project, updated_at: 2.days.ago)
      newer = create(:issue, project: project, updated_at: 1.day.ago)

      result = tool.call(project_id: project.id, limit: 1)

      expect(result.map { |entry| entry[:id] }).to eq([ newer.id ])
      expect(result.map { |entry| entry[:id] }).not_to include(older.id)
    end

    it "raises for projects outside the user's account" do
      other_project = create(:project)

      expect { tool.call(project_id: other_project.id) }
        .to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
