# frozen_string_literal: true

require "rails_helper"

RSpec.describe Tools::GetProjectPullRequests do
  let(:account) { create(:account) }
  let(:user) { create(:user, :member, account: account) }
  let(:session) { create(:chat_session, account: account, created_by: user) }
  let(:tool) { described_class.new(user: user, session: session) }
  let(:project) { create(:project, account: account) }

  describe "#call" do
    # @spec AUTO-MERGE-012
    it "distinguishes technical work from a simultaneous human review request" do
      pr = create(:issue, :pull_request, project:,
        technical_merge_blockers: [ { "key" => "sdk", "reason" => "SDK failure" } ])
      expect(tool.call(project_id: project.id).sole).to include(
        human_review_requested: false, technical_merge_blocker_count: 1)

      pr.update!(labels: [ "paid-hold-review" ])
      expect(tool.call(project_id: project.id).sole).to include(
        human_review_requested: true, technical_merge_blocker_count: 1)
    end

    it "returns only pull requests" do
      pr = create(:issue, :pull_request, project: project)
      create(:issue, project: project)

      result = tool.call(project_id: project.id)

      expect(result.map { |entry| entry[:id] }).to eq([ pr.id ])
    end

    it "filters by GitHub state" do
      open_pr = create(:issue, :pull_request, project: project, github_state: "open")
      create(:issue, :pull_request, project: project, github_state: "closed")

      result = tool.call(project_id: project.id, github_state: "open")

      expect(result.map { |entry| entry[:id] }).to eq([ open_pr.id ])
    end

    it "clamps the limit" do
      older = create(:issue, :pull_request, project: project, updated_at: 2.days.ago)
      newer = create(:issue, :pull_request, project: project, updated_at: 1.day.ago)

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
