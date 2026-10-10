# frozen_string_literal: true

require "rails_helper"

# @spec INBOX-FOUNDATION-010
RSpec.describe Inbox::Availability do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project_a) do
    create(
      :project,
      account: account,
      created_by: user,
      auto_pick_enabled: true,
      active: true,
      auto_merge_mode: "all",
      owner_reviewer_login: "viamin",
      owner: "acme",
      repo: "alpha"
    )
  end
  let(:project_b) do
    create(
      :project,
      account: account,
      created_by: user,
      auto_pick_enabled: true,
      active: true,
      owner: "acme",
      repo: "beta"
    )
  end

  describe "#kind_counts and #available_kinds" do
    it "counts entries per kind across visible projects and hides kinds with nothing waiting" do
      create(:issue, :needs_input, project: project_a)
      create(:issue, :needs_input, project: project_b)
      create(:issue, project: project_a, paid_state: "manual_review", manual_review_reason: "Round limit reached.")

      availability = described_class.call(user: user)

      expect(availability.kind_counts[Inbox::Queue::CLARIFYING_QUESTIONS_KIND]).to eq(2)
      expect(availability.kind_counts[Inbox::Queue::MANUAL_REVIEW_KIND]).to eq(1)
      expect(availability.available_kinds).to contain_exactly(
        Inbox::Queue::CLARIFYING_QUESTIONS_KIND, Inbox::Queue::MANUAL_REVIEW_KIND
      )
    end

    it "narrows kind counts to the active project filter" do
      create(:issue, :needs_input, project: project_a)
      create(:issue, :needs_input, project: project_b)
      create(:issue, project: project_b, paid_state: "manual_review", manual_review_reason: "Round limit reached.")

      availability = described_class.call(user: user, project: project_a)

      expect(availability.kind_counts[Inbox::Queue::CLARIFYING_QUESTIONS_KIND]).to eq(1)
      expect(availability.available_kinds).to contain_exactly(Inbox::Queue::CLARIFYING_QUESTIONS_KIND)
    end

    # @spec OPERATOR-INBOX-002E @spec CHANGE-INTENT-INBOX-001
    it "counts retry-limited issues and pending change-intent drafts" do
      create(:issue, project: project_a, runner_retry_abandoned_at: 1.hour.ago, runner_retry_abandon_reason: "capped")
      create(:change_intent, :draft, project: project_b)

      availability = described_class.call(user: user)

      expect(availability.kind_counts[Inbox::Queue::RETRY_LIMITED_KIND]).to eq(1)
      expect(availability.kind_counts[Inbox::Queue::CHANGE_INTENT_DRAFT_KIND]).to eq(1)
    end

    # @spec OPERATOR-INBOX-002A
    it "counts merge-approval candidates via the shared signal check" do
      create(
        :issue, :pull_request, project: project_a,
        auto_merge_evaluated_at: Time.current, awaiting_approval_since: 2.hours.ago,
        auto_merge_blockers: {
          "failed" => [ { "signal" => "owner_approved", "status" => "failed" } ],
          "not_evaluated" => []
        }
      )

      availability = described_class.call(user: user)

      expect(availability.kind_counts[Inbox::Queue::MERGE_APPROVAL_KIND]).to eq(1)
    end
  end

  describe "#project_counts and #available_projects" do
    it "counts entries per project and hides projects with nothing waiting" do
      create(:issue, :needs_input, project: project_a)
      untouched_project = create(:project, account: account, created_by: user, active: true, owner: "acme", repo: "gamma")

      availability = described_class.call(user: user)

      expect(availability.project_counts[project_a.id]).to eq(1)
      expect(availability.available_projects).to contain_exactly(project_a)
      expect(availability.available_projects).not_to include(untouched_project)
    end

    it "narrows project counts to the active kind filter" do
      create(:issue, :needs_input, project: project_a)
      create(:issue, project: project_b, paid_state: "manual_review", manual_review_reason: "Round limit reached.")

      availability = described_class.call(user: user, kind: Inbox::Queue::MANUAL_REVIEW_KIND)

      expect(availability.available_projects).to contain_exactly(project_b)
      expect(availability.project_counts[project_b.id]).to eq(1)
    end
  end

  describe "#total_count" do
    it "ignores the active filters and matches Inbox::Count's unfiltered badge" do
      create(:issue, :needs_input, project: project_a)
      create(:issue, project: project_b, paid_state: "manual_review", manual_review_reason: "Round limit reached.")

      availability = described_class.call(user: user, kind: Inbox::Queue::MANUAL_REVIEW_KIND, project: project_b)

      expect(availability.total_count).to eq(2)
      expect(availability.total_count).to eq(Inbox::Count.call(user: user))
    end
  end

  describe "#project_ids_for and #kinds_for" do
    it "exposes the full kind<->project matrix independent of the active filters" do
      create(:issue, :needs_input, project: project_a)
      create(:issue, project: project_b, paid_state: "manual_review", manual_review_reason: "Round limit reached.")

      availability = described_class.call(user: user, kind: Inbox::Queue::MANUAL_REVIEW_KIND)

      expect(availability.project_ids_for(Inbox::Queue::CLARIFYING_QUESTIONS_KIND)).to contain_exactly(project_a.id)
      expect(availability.kinds_for(project_b)).to contain_exactly(Inbox::Queue::MANUAL_REVIEW_KIND)
    end
  end

  # @spec INBOX-FOUNDATION-006
  it "excludes projects the operator cannot see" do
    other_user = create(:user, account: create(:account))
    hidden_project = create(:project, account: other_user.account, created_by: other_user, active: true, owner: "acme", repo: "hidden")
    create(:issue, :needs_input, project: hidden_project)

    availability = described_class.call(user: user)

    expect(availability.total_count).to eq(0)
  end
end
