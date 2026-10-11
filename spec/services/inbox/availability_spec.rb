# frozen_string_literal: true

require "rails_helper"

# @spec INBOX-FOUNDATION-010
RSpec.describe Inbox::Availability do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:questions_body) do
    <<~BODY
      <!-- paid:enhance-issue -->

      ## Clarifying questions
      1. What is the expected behavior?
    BODY
  end
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
      create(:issue, :needs_input, project: project_a, body: questions_body)
      create(:issue, :needs_input, project: project_b, body: questions_body)
      create(:issue, project: project_a, paid_state: "manual_review", manual_review_reason: "Round limit reached.")

      availability = described_class.call(user: user)

      expect(availability.kind_counts[Inbox::Queue::CLARIFYING_QUESTIONS_KIND]).to eq(2)
      expect(availability.kind_counts[Inbox::Queue::MANUAL_REVIEW_KIND]).to eq(1)
      expect(availability.available_kinds).to contain_exactly(
        Inbox::Queue::CLARIFYING_QUESTIONS_KIND, Inbox::Queue::MANUAL_REVIEW_KIND
      )
    end

    it "narrows kind counts to the active project filter" do
      create(:issue, :needs_input, project: project_a, body: questions_body)
      create(:issue, :needs_input, project: project_b, body: questions_body)
      create(:issue, project: project_b, paid_state: "manual_review", manual_review_reason: "Round limit reached.")

      availability = described_class.call(user: user, project: project_a)

      expect(availability.kind_counts[Inbox::Queue::CLARIFYING_QUESTIONS_KIND]).to eq(1)
      expect(availability.available_kinds).to contain_exactly(Inbox::Queue::CLARIFYING_QUESTIONS_KIND)
    end

    it "excludes questionless needs-input issues that the queue cannot render" do
      create(:issue, :needs_input, project: project_a, body: "Needs manual retry")

      availability = described_class.call(user: user)

      expect(availability.kind_counts[Inbox::Queue::CLARIFYING_QUESTIONS_KIND]).to eq(0)
      expect(availability.available_kinds).not_to include(Inbox::Queue::CLARIFYING_QUESTIONS_KIND)
      expect(availability.available_projects).not_to include(project_a)
      expect(availability.total_count).to eq(0)
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
      create(:issue, :needs_input, project: project_a, body: questions_body)
      untouched_project = create(:project, account: account, created_by: user, active: true, owner: "acme", repo: "gamma")

      availability = described_class.call(user: user)

      expect(availability.project_counts[project_a.id]).to eq(1)
      expect(availability.available_projects).to contain_exactly(project_a)
      expect(availability.available_projects).not_to include(untouched_project)
    end

    it "narrows project counts to the active kind filter" do
      create(:issue, :needs_input, project: project_a, body: questions_body)
      create(:issue, project: project_b, paid_state: "manual_review", manual_review_reason: "Round limit reached.")

      availability = described_class.call(user: user, kind: Inbox::Queue::MANUAL_REVIEW_KIND)

      expect(availability.available_projects).to contain_exactly(project_b)
      expect(availability.project_counts[project_b.id]).to eq(1)
    end
  end

  describe "#total_count" do
    it "ignores the active filters and matches Inbox::Count's unfiltered badge" do
      create(:issue, :needs_input, project: project_a, body: questions_body)
      create(:issue, project: project_b, paid_state: "manual_review", manual_review_reason: "Round limit reached.")

      availability = described_class.call(user: user, kind: Inbox::Queue::MANUAL_REVIEW_KIND, project: project_b)

      expect(availability.total_count).to eq(2)
      expect(availability.total_count).to eq(Inbox::Count.call(user: user))
    end
  end

  describe "#project_ids_for and #kinds_for" do
    it "exposes the full kind<->project matrix independent of the active filters" do
      create(:issue, :needs_input, project: project_a, body: questions_body)
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
    create(:issue, :needs_input, project: hidden_project, body: questions_body)

    availability = described_class.call(user: user)

    expect(availability.total_count).to eq(0)
  end

  # Every /inbox render reads the matrix (available_projects is built in
  # load_inbox), so like the Inbox::Count badge it must be cached behind the
  # dashboard cache version instead of re-running all twelve lanes per
  # request.
  describe "matrix caching" do
    around do |example|
      original_store = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      example.run
    ensure
      Rails.cache = original_store
    end

    # @spec INBOX-FOUNDATION-010
    it "caches the per-user matrix for the TTL so repeated renders skip the lane work" do
      issue = create(:issue, :needs_input, project: project_a, body: questions_body)
      # Capture the counts eagerly — the Availability readers are lazy, so
      # deferring them to assertion time would re-read the (now mutated)
      # cache instead of the value the first call produced.
      first = described_class.call(user: user).kind_counts[Inbox::Queue::CLARIFYING_QUESTIONS_KIND]

      # update_column bypasses the model callbacks that bump the inbox cache
      # version, isolating the TTL behavior (the same trick Count's spec
      # uses).
      issue.update_column(:github_state, "closed")
      cached = described_class.call(user: user).kind_counts[Inbox::Queue::CLARIFYING_QUESTIONS_KIND]

      expect(first).to eq(1)
      expect(cached).to eq(1)
    end

    # @spec INBOX-FOUNDATION-010
    it "refreshes the matrix after the inbox cache version bumps" do
      issue = create(:issue, :needs_input, project: project_a, body: questions_body)
      described_class.call(user: user).kind_counts[Inbox::Queue::CLARIFYING_QUESTIONS_KIND]

      issue.update_column(:github_state, "closed")
      Dashboard::CacheVersion.bump(account, scope: Dashboard::CacheVersion::INBOX_SCOPE)
      refreshed = described_class.call(user: user)

      expect(refreshed.kind_counts[Inbox::Queue::CLARIFYING_QUESTIONS_KIND]).to eq(0)
      expect(refreshed.total_count).to eq(0)
    end

    # @spec INBOX-FOUNDATION-006
    it "keeps each operator's matrix in a separate cache entry" do
      create(:issue, :needs_input, project: project_a, body: questions_body)
      described_class.call(user: user)

      other_user = create(:user, account: account)

      expect(described_class.call(user: other_user).total_count).to eq(0)
    end
  end
end
