# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::StalledCloseoutProjection do # @spec PARTIAL-CLOSEOUT-042
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) do
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

  def create_stalled_issue(github_number:, merged_pr_number: 14, **attrs)
    issue_project = attrs.delete(:project) || project
    issue = create(:issue, project: issue_project, github_number: github_number, paid_state: "in_progress", **attrs)
    create(
      :issue,
      :pull_request,
      project: issue_project,
      github_number: merged_pr_number,
      github_state: "closed",
      pr_review_phase: "merged",
      parent_issue_id: issue.id,
      created_at: 2.days.ago
    )
    issue
  end

  def enable_projection!(for_project: project)
    FeatureFlags.enable!(described_class::FLAG, project: for_project)
  end

  def count_eligibility_evaluations
    evaluations = []
    allow(Automation::Strategies::AutoPick::DefaultCandidateSource).to receive(:partial_closeout_eligibility)
      .and_wrap_original { |method, *args, **kwargs|
        evaluations << args
        method.call(*args, **kwargs)
      }
    evaluations
  end

  describe ".recompute" do
    it "persists a successful checkpoint and one serialized stall row per stalled issue" do
      issue = create_stalled_issue(github_number: 41)

      result = described_class.recompute(project)

      checkpoint = PartialCloseoutStallCheckpoint.find_by!(project: project)
      expect(result).to have_attributes(project_id: project.id, generation: 1, stall_count: 1)
      expect(checkpoint).to be_successful
      expect(checkpoint).to have_attributes(generation: 1, input_watermark: checkpoint.computed_at, last_failure: {})

      stall = PartialCloseoutStall.find_by!(issue: issue)
      expect(stall).to have_attributes(project: project, projection_generation: 1)
      expect(stall.evidence_digest).to eq(closeout_digest_for(issue))
      expect(stall.status["outcome"]).to include("merged partial PR #14")
      expect(stall.status["reason"]).to include("only a deliberate continuation can lift it once")
      expect(stall.status["evidence"]["merged_prs"].first).to include("number" => 14)
    end

    it "records an empty successful checkpoint for a project with no stalls, distinguishable from unevaluated" do
      create(:issue, project: project, github_number: 1, paid_state: "in_progress")

      result = described_class.recompute(project)

      checkpoint = PartialCloseoutStallCheckpoint.find_by!(project: project)
      expect(result.stall_count).to eq(0)
      expect(checkpoint).to be_successful
      expect(PartialCloseoutStall.where(project: project)).to be_empty
      expect(PartialCloseoutStallCheckpoint.where(project: create(:project, account: account))).to be_none
    end

    it "materializes the persisted row back into the live CloseoutStatus shape" do
      issue = create_stalled_issue(github_number: 42)
      blocker_issue = create(:issue, project: project, github_number: 77, github_state: "open", paid_state: "in_progress")
      create(:issue_dependency, issue: issue, depends_on_issue: blocker_issue)
      described_class.recompute(project)

      status = described_class.read([ project ]).find { |pair| pair.issue == issue }.status

      expect(status).to be_stalled
      expect(status.blockers.first).to have_attributes(code: :unmet_prerequisites, recovery: String)
      expect(status.blockers.first.message).to include("#77")
      expect(status.unresolved_prerequisites).to eq([ "#77" ])
      expect(status.evidence.merged_prs.map(&:number)).to eq([ 14 ])
      expect(status.evidence.merged_prs.first.url).to be_present
      expect(status.evidence.terminal_at).to be_present
      expect(status.outcome).to include("merged partial PR #14")
      expect(status.reason).to eq(
        PartialCloseoutStall.find_by!(issue: issue).status["reason"]
      )
    end

    it "never mutates paid_state or grants a continuation" do
      issue = create_stalled_issue(github_number: 43)

      described_class.recompute(project)

      expect(issue.reload.paid_state).to eq("in_progress")
      expect(IssueContinuationRequest.where(issue: issue)).to be_none
      expect(AgentRun.where(issue: issue)).to be_none
    end
  end

  describe "invalidation" do
    it "removes a projected stall once a blocking run starts, and advances the checkpoint generation" do
      issue = create_stalled_issue(github_number: 44)
      described_class.recompute(project)

      create(:agent_run, :completed, project: project, issue: issue, goal: "create_pr").update!(status: "queued")

      result = described_class.recompute(project)

      expect(result.stall_count).to eq(0)
      expect(PartialCloseoutStall.where(project: project)).to be_empty
      expect(PartialCloseoutStallCheckpoint.find_by!(project: project).generation).to eq(2)
    end

    it "adds a stall when a run completes with new terminal evidence" do
      issue = create(:issue, project: project, github_number: 45, paid_state: "in_progress")
      described_class.recompute(project)
      expect(PartialCloseoutStall.where(project: project)).to be_empty

      create(
        :issue,
        :pull_request,
        project: project,
        github_number: 15,
        github_state: "closed",
        pr_review_phase: "merged",
        parent_issue_id: issue.id,
        created_at: 1.day.ago
      )
      described_class.recompute(project)

      expect(PartialCloseoutStall.find_by!(issue: issue).projection_generation).to eq(2)
    end
  end

  describe "failure retention" do
    it "keeps the previous projection and records bounded failure metadata without advancing the checkpoint" do
      issue = create_stalled_issue(github_number: 46)
      described_class.recompute(project)
      checkpoint = PartialCloseoutStallCheckpoint.find_by!(project: project)
      allow(Issues::StalledCloseouts).to receive(:call).and_raise(RuntimeError, ("boom" * 500))

      expect { described_class.recompute(project) }.to raise_error(RuntimeError)

      checkpoint.reload
      expect(checkpoint).to have_attributes(generation: 1, computed_at: checkpoint.input_watermark)
      expect(PartialCloseoutStall.find_by!(issue: issue).projection_generation).to eq(1)
      expect(checkpoint.last_failure_at).to be_present
      expect(checkpoint.last_failure["error_class"]).to eq("RuntimeError")
      expect(checkpoint.last_failure["message"].length).to eq(described_class::FAILURE_MESSAGE_LIMIT)
    end

    it "records failure metadata for an initial attempt that never succeeded" do
      allow(Issues::StalledCloseouts).to receive(:call).and_raise(RuntimeError, "boom")

      expect { described_class.recompute(project) }.to raise_error(RuntimeError)

      checkpoint = PartialCloseoutStallCheckpoint.find_by!(project: project)
      expect(checkpoint).not_to be_successful
      expect(checkpoint.last_failure_at).to be_present
    end
  end

  describe ".read" do
    let!(:issue) { create_stalled_issue(github_number: 47) }

    it "serves projected projects from persisted rows without evaluating live admission" do
      enable_projection!
      described_class.recompute(project)
      evaluations = count_eligibility_evaluations

      pairs = described_class.read([ project ])

      expect(pairs.map { |pair| pair.issue.id }).to eq([ issue.id ])
      expect(pairs.first.issue.project).to eq(project)
      expect(evaluations).to be_empty
    end

    it "keeps a flag-enabled project without a successful checkpoint on the live path" do
      enable_projection!
      evaluations = count_eligibility_evaluations

      pairs = described_class.read([ project ])

      expect(pairs.map { |pair| pair.issue.id }).to eq([ issue.id ])
      expect(evaluations).not_to be_empty
    end

    it "keeps flag-off projects on the live path" do
      evaluations = count_eligibility_evaluations

      pairs = described_class.read([ project ])

      expect(pairs.map { |pair| pair.issue.id }).to eq([ issue.id ])
      expect(evaluations).not_to be_empty
    end

    it "mixes projected and live projects in one read" do
      enable_projection!
      described_class.recompute(project)
      live_project = create(
        :project, account: account, created_by: user, auto_pick_enabled: true, active: true,
        auto_merge_mode: "all", owner_reviewer_login: "viamin", owner: "acme", repo: "beta"
      )
      live_issue = create_stalled_issue(github_number: 48, merged_pr_number: 24, project: live_project)

      pairs = described_class.read([ project, live_project ])

      expect(pairs.map { |pair| pair.issue.id }).to contain_exactly(issue.id, live_issue.id)
    end
  end

  describe "consumer agreement", :aggregate_failures do
    it "reports the same lane membership for Queue, Count, and Availability" do
      enable_projection!
      issue = create_stalled_issue(github_number: 48)
      described_class.recompute(project)
      second_project = create(
        :project, account: account, created_by: user, auto_pick_enabled: true, active: true,
        auto_merge_mode: "all", owner_reviewer_login: "viamin", owner: "acme", repo: "beta"
      )
      second_issue = create_stalled_issue(github_number: 49, merged_pr_number: 25, project: second_project)

      queue_ids = Inbox::Queue.call(user: user, kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND).map { |entry| entry.issue.id }
      availability = Inbox::Availability.new(user: user).kind_counts[Inbox::Queue::PARTIAL_CLOSEOUT_KIND]
      projection_ids = described_class.read(account.projects.active.to_a).map { |pair| pair.issue.id }
      count = Inbox::Count.new(user: user).send(:partial_closeout_count)

      expect(queue_ids).to contain_exactly(issue.id, second_issue.id)
      expect(availability).to eq(2)
      expect(count).to eq(2)
      expect(projection_ids).to contain_exactly(issue.id, second_issue.id)
    end
  end

  describe "live admission stays authoritative" do
    it "refuses a continuation taken from a stale projected entry with the real live blocker" do
      enable_projection!
      issue = create_stalled_issue(github_number: 50)
      described_class.recompute(project)
      # The projection is now stale: an open native child blocks admission but
      # no recomputation has run.
      create(:issue, project: project, github_number: 51, github_state: "open", paid_state: "in_progress", parent_issue_id: issue.id)
      entry = Inbox::Queue.call(user: user, kind: Inbox::Queue::PARTIAL_CLOSEOUT_KIND).find { |candidate| candidate.issue == issue }
      expect(entry).to be_present

      result = Issues::RequestContinuation.call(issue: issue, actor: user, reason: "finish the remainder")

      expect(result.success?).to be(false)
      expect(result.code).to eq(:open_native_children)
      expect(result.message).to include("#51")
    end
  end

  describe ".schedule" do
    it "enqueues a recomputation only for a flag-enabled project" do
      project
      expect { described_class.schedule(project) }.not_to change { ActiveJob::Base.queue_adapter.enqueued_jobs.size }

      enable_projection!
      described_class.schedule(project)

      expect(RecomputeStalledCloseoutProjectionJob).to have_been_enqueued.with(project.id)
    end
  end

  describe ".due_projects" do
    it "is always due without a successful checkpoint, even when the flag is on" do
      enable_projection!
      issue = create_stalled_issue(github_number: 52)

      expect(described_class.due_projects(account)).to eq([ project ])
      expect(issue).to be_present
    end

    it "is not due while no admission-relevant input changed after the watermark" do
      enable_projection!
      create_stalled_issue(github_number: 53)
      travel_to(2.minutes.from_now) { described_class.recompute(project) }

      expect(described_class.due_projects(account)).to be_empty
    end

    it "becomes due when an admission-relevant input changes after the watermark" do
      enable_projection!
      issue = create_stalled_issue(github_number: 54)
      travel_to(2.minutes.from_now) { described_class.recompute(project) }
      expect(described_class.due_projects(account)).to be_empty

      travel_to(5.minutes.from_now) { issue.touch }

      expect(described_class.due_projects(account)).to eq([ project ])
    end

    it "becomes due when an issue continuation request changes after the watermark" do
      enable_projection!
      issue = create_stalled_issue(github_number: 55)
      travel_to(2.minutes.from_now) { described_class.recompute(project) }

      travel_to(5.minutes.from_now) do
        create(:issue_continuation_request, issue: issue, project: project, requested_by: user)
      end

      expect(described_class.due_projects(account)).to eq([ project ])
    end

    it "ignores accounts whose projects have the flag off" do
      create_stalled_issue(github_number: 56)

      expect(described_class.due_projects(account)).to be_empty
    end
  end

  describe ".resolve_enabled" do
    it "resolves per-project actor gates without querying per project" do
      other_project = create(:project, account: account, created_by: user, active: true, owner: "acme", repo: "gamma")
      enable_projection!

      expect(described_class.resolve_enabled([ project, other_project ])).to eq([ project ])
    end

    it "resolves a tenant-wide override to every project" do
      other_project = create(:project, account: account, created_by: user, active: true, owner: "acme", repo: "delta")
      account.create_tenant_setting!(features: { described_class::FLAG.to_s => true })

      expect(described_class.resolve_enabled([ project, other_project ])).to contain_exactly(project, other_project)
    end
  end

  private

  def closeout_digest_for(issue)
    Issues::CloseoutEvidence.call(issue).digest
  end
end
