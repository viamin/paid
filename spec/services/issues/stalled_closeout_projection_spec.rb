# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::StalledCloseoutProjection do # @spec PARTIAL-CLOSEOUT-042
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:) }
  let(:project) do
    create(
      :project,
      account: account,
      created_by: owner,
      auto_pick_enabled: true,
      active: true,
      owner: "acme",
      repo: "alpha"
    )
  end
  let(:issue) { create(:issue, project: project, github_state: "open", paid_state: "in_progress") }

  before { FeatureFlags.enable!(:partial_closeout_lane_read_model, project:) }

  def merged_pr_row(number:, parent: issue, **attrs)
    create(
      :issue,
      :pull_request,
      project: parent.project,
      github_number: number,
      github_state: "closed",
      pr_review_phase: "merged",
      parent_issue_id: parent.id,
      **attrs
    )
  end

  def seed_stall(parent: issue, number: 12)
    merged_pr_row(number: number, parent: parent)
    parent
  end

  describe ".recompute" do
    it "persists a checkpoint and a stalled-issue row that mirror the live evaluation" do
      seed_stall
      live = Issues::StalledCloseouts.pairs_for(project)

      result = described_class.recompute(project)

      expect(result).to be_success
      check = StalledCloseoutProjectionCheck.find_by!(project: project)
      expect(check.computed_at).to be_present
      expect(check.generation).to eq(1)
      expect(check.input_watermark).to be_present
      rows = StalledCloseoutProjectionRow.where(project: project)
      expect(rows.map(&:issue_id)).to contain_exactly(issue.id)
      row = rows.first
      expect(row.evidence_digest).to eq(live.first.status.evidence.digest)
      expect(row.projection_generation).to eq(check.generation)
      expect(row.status_result.stalled?).to be(true)
    end

    it "rehydrates the recorded outcome, reason, and evidence for display" do
      seed_stall
      live = Issues::StalledCloseouts.pairs_for(project)
      described_class.recompute(project)

      row = StalledCloseoutProjectionRow.find_by!(project: project, issue: issue)
      status = row.status_result

      expect(status.reason).to eq(live.first.status.reason)
      expect(status.outcome).to eq(live.first.status.outcome)
      expect(status.evidence.merged_prs.map(&:number)).to contain_exactly(12)
      expect(status.evidence.terminal_at).to be_present
      expect(status.evidence.digest).to eq(live.first.status.evidence.digest)
    end

    it "records an evaluated project with no stalls as a successful checkpoint with zero rows" do
      create(:issue, project: project, github_state: "open", paid_state: "in_progress")

      result = described_class.recompute(project)

      expect(result).to be_success
      check = StalledCloseoutProjectionCheck.find_by!(project: project)
      expect(check.computed_at).to be_present
      expect(StalledCloseoutProjectionRow.where(project: project)).to be_empty
    end

    it "removes a projected stall the live admission scope no longer holds" do
      seed_stall
      described_class.recompute(project)
      expect(StalledCloseoutProjectionRow.where(project: project)).to be_present

      create(:agent_run, project: project, issue: issue, goal: "create_pr", status: "queued")
      described_class.recompute(project)

      expect(StalledCloseoutProjectionRow.where(project: project)).to be_empty
      check = StalledCloseoutProjectionCheck.find_by!(project: project)
      expect(check.generation).to eq(2)
    end

    it "adds a stall when a completed run records new terminal closeout evidence" do
      create(:issue, project: project, github_state: "open", paid_state: "in_progress")
      described_class.recompute(project)
      expect(StalledCloseoutProjectionRow.where(project: project)).to be_empty

      seed_stall
      create(
        :agent_run, :completed, project: project, issue: issue, goal: "create_pr",
        pull_request_number: 12, pull_request_url: "https://github.com/acme/alpha/pull/12"
      )
      described_class.recompute(project)

      expect(StalledCloseoutProjectionRow.where(project: project).map(&:issue_id)).to contain_exactly(issue.id)
    end

    it "keeps the previous projection when a recomputation fails" do
      seed_stall
      described_class.recompute(project)
      check = StalledCloseoutProjectionCheck.find_by!(project: project)
      computed_at_before = check.computed_at
      watermark_before = check.input_watermark
      rows_before = StalledCloseoutProjectionRow.where(project: project).to_a

      allow(Issues::StalledCloseouts).to receive(:pairs_for).and_raise(ActiveRecord::StatementInvalid.new("boom"))
      result = described_class.recompute(project)

      expect(result).not_to be_success
      check.reload
      expect(check.computed_at).to eq(computed_at_before)
      expect(check.input_watermark).to eq(watermark_before)
      expect(check.generation).to eq(1)
      expect(check.last_failure_at).to be_present
      expect(check.last_failure["error_class"]).to eq("ActiveRecord::StatementInvalid")
      expect(check.last_failure["message"]).to include("boom")
      expect(StalledCloseoutProjectionRow.where(project: project).map(&:id)).to match_array(rows_before.map(&:id))
    end

    it "never mutates paid_state or grants a continuation" do
      seed_stall

      expect { described_class.recompute(project) }
        .not_to change { [ issue.reload.paid_state, IssueContinuationRequest.count ] }
    end

    it "advances the checkpoint but keeps failure metadata from an earlier failed attempt" do
      seed_stall
      allow(Issues::StalledCloseouts).to receive(:pairs_for).and_raise(ActiveRecord::StatementInvalid.new("boom"))
      described_class.recompute(project)
      allow(Issues::StalledCloseouts).to receive(:pairs_for).and_call_original

      result = described_class.recompute(project)

      expect(result).to be_success
      check = StalledCloseoutProjectionCheck.find_by!(project: project)
      expect(check.last_failure_at).to be_present
      expect(check.computed_at).to be > check.last_failure_at
    end
  end

  describe ".input_watermark and .due?" do
    it "marks every admission-relevant input change due for recomputation" do
      seed_stall
      described_class.recompute(project)
      expect(described_class.due?(project)).to be(false)

      create(:agent_run, project: project, issue: issue, goal: "create_pr", status: "queued")
      expect(described_class.due?(project)).to be(true)

      described_class.recompute(project)
      expect(described_class.due?(project)).to be(false)

      create(:issue, project: project, github_state: "open", paid_state: "in_progress")
      expect(described_class.due?(project)).to be(true)
    end

    it "marks a project without a successful checkpoint always due" do
      seed_stall

      expect(described_class.due?(project)).to be(true)
    end
  end

  describe ".pairs_for (shared reader)" do
    it "reads projected rows for checkpointed projects without the live admission scope" do
      seed_stall
      described_class.recompute(project)

      pairs = described_class.pairs_for([ project.reload ])

      expect(pairs.map { |pair| pair.issue.id }).to contain_exactly(issue.id)
      expect(pairs.first.status.stalled?).to be(true)
      expect(pairs.first.status.evidence.digest).to eq(Issues::CloseoutEvidence.call(issue).digest)
    end

    it "reports an evaluated empty project as empty, not unevaluated" do
      create(:issue, project: project, github_state: "open", paid_state: "in_progress")
      described_class.recompute(project)

      expect(described_class.pairs_for([ project.reload ])).to be_empty
    end

    it "keeps a flag-enabled project without a checkpoint on the live path" do
      seed_stall

      allow(Issues::StalledCloseouts).to receive(:call).and_call_original
      pairs = described_class.pairs_for([ project.reload ])

      expect(pairs.map { |pair| pair.issue.id }).to contain_exactly(issue.id)
      expect(Issues::StalledCloseouts).to have_received(:call).with([ project ], issue_id: nil)
    end

    it "falls back to the live path for projects where the rollout guard is disabled" do
      other_project = create(:project, account: account, created_by: owner, auto_pick_enabled: true)
      other_issue = create(:issue, project: other_project, github_state: "open", paid_state: "in_progress")
      merged_pr_row(number: 31, parent: other_issue)
      seed_stall
      described_class.recompute(project)

      pairs = described_class.pairs_for([ project.reload, other_project ])

      expect(pairs.map { |pair| pair.issue.id }).to contain_exactly(issue.id, other_issue.id)
    end

    it "filters projected rows by issue id for the targeted-entry path" do
      other_issue = create(:issue, project: project, github_state: "open", paid_state: "in_progress")
      merged_pr_row(number: 13, parent: issue)
      merged_pr_row(number: 14, parent: other_issue)
      described_class.recompute(project)

      pairs = described_class.pairs_for([ project.reload ], issue_id: other_issue.id)

      expect(pairs.map { |pair| pair.issue.id }).to contain_exactly(other_issue.id)
    end
  end

  describe "tenant row-level scoping", :tenant_isolation do
    around do |example|
      skip "requires CREATE ROLE privilege for RLS policy checks" unless can_manage_roles?

      setup_restricted_role
      example.run
    ensure
      ActiveRecord::Base.connection.execute("RESET ROLE")
      cleanup_restricted_role
    end

    it "never exposes another account's projection" do
      other_project = seed_other_account_projection
      TenantContext.with_system_access do
        described_class.recompute(project)
        described_class.recompute(other_project)
      end

      as_restricted_role do
        TenantContext.with(account) do
          expect(StalledCloseoutProjectionCheck.where(project_id: other_project.id)).to be_empty
          expect(StalledCloseoutProjectionRow.where(project_id: other_project.id)).to be_empty
          expect(StalledCloseoutProjectionCheck.where(project_id: project.id)).to be_present
          expect(described_class.pairs_for([ project ]).map { |pair| pair.issue.id })
            .to contain_exactly(issue.id)
        end
      end
    end

    private

    def seed_other_account_projection
      TenantContext.with_system_access do
        other_account = create(:account)
        other_owner = create(:user, account: other_account)
        other_project = create(:project, account: other_account, created_by: other_owner, auto_pick_enabled: true)
        other_issue = create(:issue, project: other_project, github_state: "open", paid_state: "in_progress")
        create(
          :issue, :pull_request, project: other_project, github_number: 77, github_state: "closed",
          pr_review_phase: "merged", parent_issue_id: other_issue.id
        )
        seed_stall
        other_project
      end
    end

    def setup_restricted_role
      cleanup_restricted_role
      connection = ActiveRecord::Base.connection
      connection.execute("CREATE ROLE paid_rls_spec NOLOGIN")
      connection.execute("GRANT USAGE ON SCHEMA public TO paid_rls_spec")
      connection.execute("GRANT SELECT ON ALL TABLES IN SCHEMA public TO paid_rls_spec")
      connection.execute("GRANT paid_rls_spec TO current_user")
    end

    def as_restricted_role
      ActiveRecord::Base.connection.execute("SET ROLE paid_rls_spec")
      yield
    ensure
      ActiveRecord::Base.connection.execute("RESET ROLE")
    end

    def cleanup_restricted_role
      return unless ActiveRecord::Base.connection.select_value("SELECT 1 FROM pg_roles WHERE rolname = 'paid_rls_spec'")

      connection = ActiveRecord::Base.connection
      connection.execute("GRANT paid_rls_spec TO current_user")
      connection.execute("DROP OWNED BY paid_rls_spec")
      connection.execute("DROP ROLE paid_rls_spec")
    end

    def can_manage_roles?
      ActiveModel::Type::Boolean.new.cast(
        ActiveRecord::Base.connection.select_value("SELECT rolcreaterole FROM pg_roles WHERE rolname = current_user")
      )
    end
  end

  describe "recomputation triggers" do
    it "schedules recomputation when closeout evidence or an explicit hold changes" do
      issue
      allow(issue).to receive(:sync_paused_label_to_github)

      expect { issue.update!(paused: true) }
        .to have_enqueued_job(RecomputeStalledCloseoutProjectionJob).with(project.id)
    end

    it "schedules recomputation when a blocking run starts" do
      issue

      expect do
        create(:agent_run, project: project, issue: issue, goal: "create_pr", status: "queued")
      end.to have_enqueued_job(RecomputeStalledCloseoutProjectionJob).with(project.id)
    end

    it "schedules recomputation when a continuation request opens" do
      issue

      expect do
        create(:issue_continuation_request, issue: issue, project: project,
          requested_by: create(:user, account: account))
      end.to have_enqueued_job(RecomputeStalledCloseoutProjectionJob).with(project.id)
    end

    it "schedules recomputation when admission-relevant runner configuration changes" do
      expect { create(:runner, user: owner) }
        .to have_enqueued_job(RecomputeStalledCloseoutProjectionJob).with(project.id)
    end

    it "ignores an unrelated issue edit" do
      issue

      expect { issue.update_columns(title: "reworded") }.not_to have_enqueued_job
    end
  end

  describe ".schedule" do
    it "enqueues a recomputation job for a rollout-enabled project" do
      expect do
        described_class.schedule(project)
      end.to have_enqueued_job(RecomputeStalledCloseoutProjectionJob).with(project.id)
    end

    it "does not enqueue for a project where the guard is disabled" do
      plain_project = create(:project, account: account, created_by: owner)

      expect do
        described_class.schedule(plain_project)
      end.not_to have_enqueued_job
    end
  end
end
