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
  let(:issue) { create(:issue, project: project, github_state: "open", paid_state: "in_progress") }

  def merged_pr_row(number:, parent_issue_id: nil)
    create(
      :issue,
      :pull_request,
      project: project,
      github_number: number,
      github_state: "closed",
      pr_review_phase: "merged",
      parent_issue_id: parent_issue_id
    )
  end

  def successful_projection!
    merged_pr_row(number: 18, parent_issue_id: issue.id)
    recompute!
    [ PartialCloseoutStallCheckpoint.sole, PartialCloseoutStall.sole ]
  end

  def enroll!
    FeatureFlags.enable!(:partial_closeout_lane_read_model, project: project)
  end

  def recompute!
    described_class.recompute!(project)
  end

  describe ".recompute!" do
    it "persists the projected stall and a successful checkpoint from the live evaluation" do
      merged_pr_row(number: 12, parent_issue_id: issue.id)

      result = recompute!

      expect(result).to have_attributes(success?: true, stalled_count: 1)
      stall = PartialCloseoutStall.find_by(issue: issue)
      expect(stall).to be_present
      expect(stall.evidence_digest).to eq(stall.status.fetch("digest"))
      expect(stall.projection_generation).to eq(1)
      expect(stall.status.fetch("reason")).to include("#12")
      expect(stall.blockers).to be_empty

      checkpoint = PartialCloseoutStallCheckpoint.find_by(project: project)
      expect(checkpoint).to be_evaluated
      expect(checkpoint).to have_attributes(generation: 1, input_watermark: be_present)
    end

    it "records the outcome, prerequisites, blockers, and technical evidence the Inbox renders" do
      merged_pr_row(number: 13, parent_issue_id: issue.id)
      child = create(:issue, project: project, github_state: "open", paid_state: "in_progress",
        parent_issue_id: issue.id, github_number: 77)
      create(:issue_dependency, issue: issue, depends_on_issue: child)

      recompute!
      stall = PartialCloseoutStall.sole
      status = stall.status

      expect(status.fetch("outcome")).to be_present
      expect(status.fetch("unresolved_prerequisites")).to eq([ "#77" ])
      expect(status.fetch("merged_prs")).to include(hash_including("number" => 13))
      expect(stall.blockers.map { |blocker| blocker.fetch("code") }).to include("unmet_prerequisites")
      # The rehydrated result keeps the blocker semantics the detail pane renders.
      pair = described_class.reader_for([ project ]).pairs.sole
      expect(pair.status.stalled?).to be(true)
      expect(pair.status.blockers.flat_map { |blocker| blocker.evidence.fetch("prerequisites", []) })
        .to eq([ "#77" ])
      expect(pair.status.unresolved_prerequisites).to eq([ "#77" ])
      expect(child.reload.paid_state).to eq("in_progress")
    end

    it "never mutates paid_state or opens a continuation" do
      merged_pr_row(number: 14, parent_issue_id: issue.id)

      expect { recompute! }
        .not_to change { [ issue.reload.paid_state, IssueContinuationRequest.count ] }
    end

    it "atomically persists an empty-result checkpoint so evaluated-empty stays distinguishable from unevaluated" do
      recompute!

      checkpoint = PartialCloseoutStallCheckpoint.sole
      expect(checkpoint).to be_evaluated
      expect(PartialCloseoutStall.count).to eq(0)
      expect(described_class.reader_for([ project ]).pairs).to be_empty
    end

    it "advances the generation and replaces rows on every successful recomputation" do
      merged_pr_row(number: 15, parent_issue_id: issue.id)
      recompute!

      merged_pr_row(number: 16, parent_issue_id: create(:issue, project: project,
        github_state: "open", paid_state: "in_progress").id)
      result = recompute!

      expect(result.generation).to eq(2)
      expect(PartialCloseoutStall.count).to eq(2)
      expect(PartialCloseoutStall.distinct.pluck(:projection_generation)).to contain_exactly(2)
    end

    it "removes a projected stall the live admission scope no longer holds" do
      merged_pr_row(number: 17, parent_issue_id: issue.id)
      recompute!
      expect(PartialCloseoutStall.count).to eq(1)

      # The issue closes on GitHub: no longer an open stall.
      issue.update!(github_state: "closed")
      result = recompute!

      expect(result.stalled_count).to eq(0)
      expect(PartialCloseoutStall.count).to eq(0)
      expect(PartialCloseoutStallCheckpoint.sole).to be_evaluated
    end

    it "keeps the previous projection when recomputation fails" do
      enroll!
      checkpoint, stall = successful_projection!
      computed_at = checkpoint.computed_at
      generation = checkpoint.generation
      watermark = checkpoint.input_watermark

      allow(Issues::StalledCloseouts).to receive(:pairs_for).and_raise("projection exploded")
      result = recompute!

      expect(result).not_to be_success
      expect(result.error.message).to eq("projection exploded")
      expect(PartialCloseoutStall.sole.issue_id).to eq(stall.issue_id)
      expect(checkpoint.reload).to have_attributes(
        computed_at: computed_at,
        generation: generation,
        input_watermark: watermark
      )
      # The previous projection keeps serving the lane.
      expect(described_class.reader_for([ project ]).pairs.sole.issue.id).to eq(issue.id)
    end

    it "records bounded failure metadata on the checkpoint without advancing it" do
      checkpoint, = successful_projection!
      allow(Issues::StalledCloseouts).to receive(:pairs_for).and_raise("projection exploded")

      recompute!

      expect(checkpoint.reload.last_failure_at).to be_present
      expect(checkpoint.last_failure).to include(
        "error_class" => "RuntimeError",
        "message" => "projection exploded"
      )
    end
  end

  describe ".due? and .input_watermark" do
    it "is due without a successful checkpoint and settles after a recomputation" do
      expect(described_class).to be_due(project)

      recompute!
      expect(described_class).not_to be_due(project)
    end

    it "becomes due when an admission-relevant input changes after the checkpoint" do
      merged_pr_row(number: 19, parent_issue_id: issue.id)
      recompute!
      expect(described_class).not_to be_due(project)

      create(:issue, project: project, github_state: "open", paid_state: "in_progress")
      expect(described_class).to be_due(project)
    end

    it "detects destroys, which leave max(updated_at) unchanged" do
      other = create(:issue, project: project, github_state: "open", paid_state: "in_progress")
      recompute!
      expect(described_class).not_to be_due(project)

      other.destroy
      expect(described_class).to be_due(project)
    end

    it "changes when admission-relevant runner configuration changes" do
      recompute!
      watermark = PartialCloseoutStallCheckpoint.sole.input_watermark

      create(:runner, user: user)
      expect(described_class.input_watermark(project)).not_to eq(watermark)
    end
  end

  describe ".schedule and the write-path triggers" do
    it "enqueues a recomputation for an enrolled project when an issue changes" do
      enroll!

      # Rails fires multi-action after_commit callbacks once per applicable
      # action inside transactional tests, so assert at-least-once; GoodJob's
      # concurrency control bounds duplicates in production.
      expect { issue.touch }
        .to enqueue_job(PartialCloseoutStallProjectionJob).with(project.id).at_least(:once)
    end

    it "enqueues a recomputation when a blocking run changes and when a continuation request changes" do
      enroll!

      expect { create(:agent_run, :completed, project: project, issue: issue, goal: "create_pr") }
        .to enqueue_job(PartialCloseoutStallProjectionJob).with(project.id).at_least(:once)
      expect do
        create(:issue_continuation_request, issue: issue, project: project, requested_by: user)
      end.to enqueue_job(PartialCloseoutStallProjectionJob).with(project.id).at_least(:once)
    end

    it "enqueues a recomputation for the owner's projects when runner configuration changes" do
      enroll!

      expect { create(:runner, user: user) }
        .to enqueue_job(PartialCloseoutStallProjectionJob).with(project.id).at_least(:once)
    end

    it "does not enqueue for projects that are not enrolled" do
      expect { issue.touch }
        .not_to have_enqueued_job(PartialCloseoutStallProjectionJob)
    end
  end

  describe "tenant isolation" do
    it "never surfaces another account's projected stalls through the reader" do
      merged_pr_row(number: 20, parent_issue_id: issue.id)
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      other_project = create(:project, account: other_account, created_by: other_user,
        owner: "other", repo: "beta", active: true, auto_pick_enabled: true)
      other_issue = create(:issue, project: other_project, github_state: "open", paid_state: "in_progress")
      create(:issue, :pull_request, project: other_project, github_number: 30,
        github_state: "closed", pr_review_phase: "merged", parent_issue_id: other_issue.id)

      [ project, other_project ].each do |record|
        FeatureFlags.enable!(:partial_closeout_lane_read_model, project: record)
        described_class.recompute!(record)
      end
      expect(PartialCloseoutStall.count).to eq(2)

      pairs = described_class.reader_for(Project.where(id: project.id).to_a).pairs

      expect(pairs.map { |pair| pair.issue.id }).to contain_exactly(issue.id)
    end
  end
end
