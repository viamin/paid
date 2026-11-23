# frozen_string_literal: true

require "rails_helper"

RSpec.describe WorkItems::MigrateGithubIssues do
  # @spec UNIFIED-WORK-ITEMS-007 UNIFIED-WORK-ITEMS-009
  describe ".call" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account:) }

    it "imports GitHub issue provenance, Paid history, assignments, comments, and relationships idempotently" do
      parent = create(:issue, project:, paid_state: "planning")
      issue = create(:issue, project:, parent_issue: parent, paid_state: "needs_input", labels: [ "paid:needs-input" ])
      dependency = create(:issue, project:)
      create(:issue_dependency, issue:, depends_on_issue: dependency)
      run = create(:agent_run, project:, issue:)

      result = described_class.call(
        account:,
        comments: ->(legacy_issue) { [ { "id" => 42, "body" => "A retained GitHub comment", "issue" => legacy_issue.github_number } ] }
      )

      expect(result).to have_attributes(migrated_count: 3, reconciled_count: 0)
      expect_migrated_work_item(issue:, parent:, dependency:, run:)

      expect {
        described_class.call(account:, comments: ->(_) { [ { "id" => 42, "body" => "A retained GitHub comment" } ] })
      }.not_to change(WorkItem, :count)
    end

    it "reconciles only issues created or changed during the maintenance window and leaves pull requests separate" do
      before_window = create(:issue, project:, github_updated_at: 2.hours.ago)
      pull_request = create(:issue, :pull_request, project:)
      window_opened_at = 1.hour.ago
      during_window = create(:issue, project:, github_updated_at: Time.current)

      result = described_class.call(account:, since: window_opened_at, comments: ->(_) { [] })

      expect(result).to have_attributes(migrated_count: 1, reconciled_count: 1)
      expect(WorkItem.find_by(legacy_issue: before_window)).to be_nil
      expect(WorkItem.find_by(legacy_issue: during_window)).to be_present
      expect(WorkItem.find_by(legacy_issue: pull_request)).to be_nil
      expect(FeatureFlags.enabled?(:unified_work_items, project:)).to be(false)
    end

    def expect_migrated_work_item(issue:, parent:, dependency:, run:)
      work_item = WorkItem.find_by!(legacy_issue: issue)
      expect(work_item).to have_attributes(account:, provider: "github", resource_type: "issue", external_id: issue.github_issue_id.to_s,
        title: issue.title, body: issue.body, native_state: issue.github_state, paid_lifecycle_state: issue.paid_state, url: issue.github_url)
      expect(work_item.raw_payload.fetch("comments")).to eq([ { "id" => 42, "body" => "A retained GitHub comment", "issue" => issue.github_number } ])
      expect(work_item.raw_payload.dig("relationships", "parent_issue_id")).to eq(parent.id)
      expect(work_item.raw_payload.dig("relationships", "dependency_ids")).to eq([ dependency.id ])
      expect(work_item.work_item_assignments).to contain_exactly(have_attributes(project:, provenance: "manual", locked: true, default_execution: true))
      expect(run.reload.work_item).to eq(work_item)
      work_item
    end
  end
end
