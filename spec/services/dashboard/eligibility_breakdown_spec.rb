# frozen_string_literal: true

require "rails_helper"

RSpec.describe Dashboard::EligibilityBreakdown do
  around do |example|
    original_store = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    example.run
  ensure
    Rails.cache = original_store
  end

  let(:user) { create(:user) }
  let(:account) { user.account }
  let!(:project) do
    create(:project, account: account, created_by: user, auto_pick_enabled: true, active: true)
  end

  before { Rails.cache.clear }

  describe ".call" do
    it "returns an empty array when user has no auto-pick projects" do
      project.update!(auto_pick_enabled: false)

      result = described_class.call(user: user)

      expect(result).to eq([])
    end

    it "returns a breakdown with correct counts" do
      create(:issue, project: project, github_state: "open", paid_state: "new")
      create(:issue, project: project, github_state: "open", paid_state: "new", labels: [ "tracking" ])
      create(:issue, project: project, github_state: "open", paid_state: "needs_input")
      create(:issue, project: project, github_state: "open", paid_state: "in_progress")
      create(:issue, project: project, github_state: "open", paid_state: "completed")

      result = described_class.call(user: user)

      expect(result.size).to eq(1)
      bd = result.first
      expect(bd.project).to eq(project)
      expect(bd.total_open).to eq(5)
      expect(bd.eligible).to eq(1)
      expect(bd.needs_input).to eq(1)
      expect(bd.in_progress).to eq(1)
      expect(bd.completed).to eq(1)
      expect(bd.skip_label).to eq(1)
      expect(bd.other_excluded).to eq(0)
    end

    it "counts dependency-blocked issues in other_excluded" do
      blocker = create(:issue, project: project, github_state: "open", paid_state: "new")
      create(:issue, project: project, github_state: "open", paid_state: "new") do |dependent|
        create(:issue_dependency, issue: dependent, depends_on_issue: blocker)
      end

      result = described_class.call(user: user)

      bd = result.first
      expect(bd.eligible).to eq(1)
      expect(bd.other_excluded).to eq(1)
    end

    it "does not double-count recoverable-completed issues in both eligible and completed" do
      issue = create(:issue, project: project, github_state: "open", paid_state: "completed")
      create(:agent_run, :completed, :automatic, project: project, issue: issue,
        goal: "create_pr", auto_pick: true, pull_request_number: nil, pull_request_url: nil)

      result = described_class.call(user: user)

      bd = result.first
      expect(bd.eligible).to eq(1)
      expect(bd.completed).to eq(0)
      expect(bd.total_open).to eq(1)
    end

    it "excludes scheduler-paused projects" do
      project.update!(scheduler_paused_at: Time.current)

      result = described_class.call(user: user)

      expect(result).to eq([])
    end

    it "excludes account-level scheduler-paused projects" do
      account.update!(scheduler_paused_at: Time.current)

      result = described_class.call(user: user)

      expect(result).to eq([])
    end

    it "excludes quality-paused projects" do
      project.update!(quality_paused_at: Time.current)

      result = described_class.call(user: user)

      expect(result).to eq([])
    end

    it "excludes inactive projects" do
      project.update!(active: false)

      result = described_class.call(user: user)

      expect(result).to eq([])
    end

    it "excludes projects with no effective owner (auto-pick would always skip them)" do
      allow(Issues::AutoPickProjectGate).to receive(:call).with(project).and_return(false)

      result = described_class.call(user: user)

      expect(result).to eq([])
    end

    it "handles multiple projects in a single call" do
      project2 = create(:project, account: account, created_by: user,
        auto_pick_enabled: true, active: true, owner: "org", repo: "repo2")
      create(:issue, project: project, github_state: "open", paid_state: "new")
      create(:issue, project: project2, github_state: "open", paid_state: "new")

      result = described_class.call(user: user)

      expect(result.size).to eq(2)
      expect(result.map { |bd| bd.project.id }).to contain_exactly(project.id, project2.id)
    end

    it "includes orphaned projects for the account fallback owner" do
      orphaned_project = create(:project, :without_creator, account: account,
        auto_pick_enabled: true, active: true, owner: "octo", repo: "orphaned")
      create(:issue, project: orphaned_project, github_state: "open", paid_state: "new")

      result = described_class.call(user: user)

      expect(result.map { |bd| bd.project.id }).to contain_exactly(project.id, orphaned_project.id)
    end

    it "hides orphaned projects from non-fallback users" do
      non_fallback_user = create(:user, account: account)
      non_fallback_project = create(:project, account: account, created_by: non_fallback_user,
        auto_pick_enabled: true, active: true, owner: "octo", repo: "owned")
      orphaned_project = create(:project, :without_creator, account: account,
        auto_pick_enabled: true, active: true, owner: "octo", repo: "orphaned")
      create(:issue, project: non_fallback_project, github_state: "open", paid_state: "new")
      create(:issue, project: orphaned_project, github_state: "open", paid_state: "new")

      result = described_class.call(user: non_fallback_user)

      expect(result.map { |bd| bd.project.id }).to eq([ non_fallback_project.id ])
    end

    it "reuses the cached breakdown on repeat page loads" do
      create(:issue, project: project, github_state: "open", paid_state: "new")
      allow(Automation::Strategies::AutoPick::DefaultCandidateSource)
        .to receive(:eligible_scope).and_call_original

      described_class.call(user: user)
      described_class.call(user: user)

      expect(Automation::Strategies::AutoPick::DefaultCandidateSource)
        .to have_received(:eligible_scope).once
    end
  end
end
