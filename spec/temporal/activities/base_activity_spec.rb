# frozen_string_literal: true

require "rails_helper"

RSpec.describe Activities::BaseActivity do
  describe "InputNormalizer" do
    let(:activity_class) do
      Class.new(described_class) do
        def execute(input)
          input
        end
      end
    end
    let(:activity) do
      stub_const("TestBaseActivity", activity_class)
      TestBaseActivity.new
    end
    let(:connection_pool) { instance_double(ActiveRecord::ConnectionAdapters::ConnectionPool) }
    let(:executor) { object_double(Rails.application.executor) }

    before do
      allow(ActiveRecord::Base).to receive(:connection_pool).and_return(connection_pool)
      allow(connection_pool).to receive(:active_connection?).and_return(true)
      allow(connection_pool).to receive(:release_connection)
      allow(Rails.application).to receive(:executor).and_return(executor)
      allow(executor).to receive(:wrap).and_yield
    end

    it "normalizes hash inputs, wraps execution in the executor, and releases the DB connection" do
      result = activity.execute("project_id" => 123)

      expect(result).to eq(project_id: 123)
      expect(executor).to have_received(:wrap)
      expect(connection_pool).to have_received(:release_connection)
    end

    it "skips release when no active connection is checked out" do
      allow(connection_pool).to receive(:active_connection?).and_return(false)

      result = activity.execute("project_id" => 456)

      expect(result).to eq(project_id: 456)
      expect(connection_pool).not_to have_received(:release_connection)
    end

    it "releases the DB connection even when execute raises" do
      error_activity_class = Class.new(described_class) do
        def execute(_input)
          raise RuntimeError, "activity failed"
        end
      end
      stub_const("ErrorActivity", error_activity_class)
      error_activity = ErrorActivity.new

      expect { error_activity.execute("project_id" => 789) }.to raise_error(RuntimeError, "activity failed")
      expect(executor).to have_received(:wrap)
      expect(connection_pool).to have_received(:release_connection)
    end
  end

  describe "#apply_legacy_draft_followup_fallback!" do
    let(:testable_class) do
      Class.new(described_class) do
        # Expose protected methods for testing
        public :apply_legacy_draft_followup_fallback!
      end
    end
    let(:testable_activity) do
      stub_const("TestableFallbackActivity", testable_class)
      TestableFallbackActivity.new
    end
    let(:project) { create(:project) }
    let(:issue) do
      create(:issue, :pull_request, project: project,
        pr_review_phase: "draft", draft_review_count: 3)
    end

    it "sets tracking columns on a legacy terminal-failure draft followup" do
      agent_run = create(:agent_run, :failed, project: project, issue: issue,
        source_pull_request_number: 42, trigger_type: "automatic")

      testable_activity.apply_legacy_draft_followup_fallback!(agent_run)

      expect(agent_run.reload).to have_attributes(
        count_toward_draft_review_round: true,
        expected_draft_review_count: 3
      )
    end

    it "skips runs that already have tracking columns set" do
      agent_run = create(:agent_run, :failed, project: project, issue: issue,
        source_pull_request_number: 42, trigger_type: "automatic",
        count_toward_draft_review_round: true, expected_draft_review_count: 2)

      expect { testable_activity.apply_legacy_draft_followup_fallback!(agent_run) }
        .not_to change { agent_run.reload.expected_draft_review_count }
    end

    it "skips runs without an issue" do
      agent_run = create(:agent_run, :failed, project: project, issue: nil,
        source_pull_request_number: 42, trigger_type: "automatic",
        custom_prompt: "Fix it")

      testable_activity.apply_legacy_draft_followup_fallback!(agent_run)

      expect(agent_run.reload.count_toward_draft_review_round).to be(false)
    end

    it "skips runs on non-draft PRs" do
      ready_issue = create(:issue, :pull_request, project: project, pr_review_phase: "ready")
      agent_run = create(:agent_run, :failed, project: project, issue: ready_issue,
        source_pull_request_number: 42, trigger_type: "automatic")

      testable_activity.apply_legacy_draft_followup_fallback!(agent_run)

      expect(agent_run.reload.count_toward_draft_review_round).to be(false)
    end

    it "skips manually triggered runs" do
      agent_run = create(:agent_run, :failed, project: project, issue: issue,
        source_pull_request_number: 42, trigger_type: "manual")

      testable_activity.apply_legacy_draft_followup_fallback!(agent_run)

      expect(agent_run.reload.count_toward_draft_review_round).to be(false)
    end

    it "skips runs without a source_pull_request_number" do
      agent_run = create(:agent_run, :failed, project: project, issue: issue,
        trigger_type: "automatic")

      testable_activity.apply_legacy_draft_followup_fallback!(agent_run)

      expect(agent_run.reload.count_toward_draft_review_round).to be(false)
    end

    it "skips completed runs to avoid double-counting" do
      agent_run = create(:agent_run, :completed, project: project, issue: issue,
        source_pull_request_number: 42, trigger_type: "automatic")

      testable_activity.apply_legacy_draft_followup_fallback!(agent_run)

      expect(agent_run.reload.count_toward_draft_review_round).to be(false)
    end

    it "skips non-PR issues" do
      non_pr_issue = create(:issue, project: project)
      agent_run = create(:agent_run, :failed, project: project, issue: non_pr_issue,
        source_pull_request_number: 42, trigger_type: "automatic")

      testable_activity.apply_legacy_draft_followup_fallback!(agent_run)

      expect(agent_run.reload.count_toward_draft_review_round).to be(false)
    end
  end
end
