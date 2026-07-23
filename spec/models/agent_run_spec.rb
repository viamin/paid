# frozen_string_literal: true

require "rails_helper"
require "docker-api"

RSpec.describe AgentRun do
  around do |example|
    Rails.cache.clear
    example.run
    Rails.cache.clear
  end

  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:issue).optional }
    it { is_expected.to have_many(:agent_run_logs).dependent(:destroy) }
    it { is_expected.to have_many(:agent_run_phases).dependent(:destroy) }
    it { is_expected.to have_many(:orchestration_decisions).dependent(:nullify) }
  end

  describe "legacy provider aliases" do
    let(:owner) { create(:user) }
    let(:runner) { create(:runner, user: owner, runner_key: "cursor") }

    it "exposes runner-named attributes through legacy provider aliases" do
      agent_run = create(
        :agent_run,
        project: create(:project, account: owner.account, created_by: owner),
        runner: runner,
        runner_switches: 2,
        runners_attempted: [ { "runner" => runner.routing_key } ],
        final_runner: runner.routing_key
      )

      expect(agent_run.provider_id).to eq(runner.id)
      expect(agent_run.provider_switches).to eq(2)
      expect(agent_run.providers_attempted).to eq([ { "runner" => runner.routing_key } ])
      expect(agent_run.final_provider).to eq(runner.routing_key)
    end

    it "keeps runner-named attributes synchronized when legacy provider setters are used" do
      agent_run = build(:agent_run)

      agent_run.provider_id = runner.id
      agent_run.provider_switches = 3
      agent_run.providers_attempted = [ { "runner" => runner.routing_key } ]
      agent_run.final_provider = runner.routing_key

      expect(agent_run.runner_id).to eq(runner.id)
      expect(agent_run.runner_switches).to eq(3)
      expect(agent_run.runners_attempted).to eq([ { "runner" => runner.routing_key } ])
      expect(agent_run.final_runner).to eq(runner.routing_key)
    end
  end

  describe "validations" do
    subject { build(:agent_run) }

    it { is_expected.to validate_presence_of(:agent_type) }
    it { is_expected.to validate_inclusion_of(:agent_type).in_array(described_class::AGENT_TYPES) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }
    it { is_expected.to validate_presence_of(:goal) }
    it { is_expected.to validate_inclusion_of(:goal).in_array(described_class::GOALS) }
    it { is_expected.to validate_presence_of(:focus) }
    it { is_expected.to validate_inclusion_of(:focus).in_array(described_class::FOCUSES) }
    it { is_expected.to validate_inclusion_of(:execution_origin).in_array(described_class::EXECUTION_ORIGINS) }
    it { is_expected.to validate_presence_of(:trigger_type) }
    it { is_expected.to validate_inclusion_of(:trigger_type).in_array(described_class::TRIGGER_TYPES) }
    it { is_expected.to validate_length_of(:created_issue_url).is_at_most(500) }
    it { is_expected.to validate_length_of(:worktree_path).is_at_most(500) }
    it { is_expected.to validate_length_of(:branch_name).is_at_most(255) }
    it { is_expected.to validate_length_of(:base_commit_sha).is_at_most(40) }
    it { is_expected.to validate_length_of(:result_commit_sha).is_at_most(40) }
    it { is_expected.to validate_length_of(:pull_request_url).is_at_most(500) }
    it { is_expected.to validate_length_of(:temporal_workflow_id).is_at_most(255) }
    it { is_expected.to validate_length_of(:temporal_run_id).is_at_most(255) }
    it { is_expected.to validate_length_of(:container_id).is_at_most(128) }
    it { is_expected.to validate_numericality_of(:iterations).is_greater_than_or_equal_to(0).allow_nil }
    it { is_expected.to validate_numericality_of(:tokens_input).is_greater_than_or_equal_to(0).allow_nil }
    it { is_expected.to validate_numericality_of(:tokens_output).is_greater_than_or_equal_to(0).allow_nil }
    it { is_expected.to validate_numericality_of(:cost_cents).is_greater_than_or_equal_to(0).allow_nil }
    it { is_expected.to validate_numericality_of(:duration_seconds).is_greater_than_or_equal_to(0).allow_nil }
    it { is_expected.to validate_inclusion_of(:token_limit_status).in_array(described_class::TOKEN_LIMIT_STATUSES).allow_nil }

    describe "issue project validation" do
      it "allows issue from the same project" do
        project = create(:project)
        issue = create(:issue, project: project)
        agent_run = build(:agent_run, project: project, issue: issue)

        expect(agent_run).to be_valid
      end

      it "rejects issue from a different project" do
        project = create(:project)
        other_project = create(:project)
        issue = create(:issue, project: other_project)
        agent_run = build(:agent_run, project: project, issue: issue)

        expect(agent_run).not_to be_valid
        expect(agent_run.errors[:issue]).to include("must belong to the same project")
      end

      it "allows nil issue when custom_prompt is present" do
        agent_run = build(:agent_run, issue: nil, custom_prompt: "Do something")

        expect(agent_run).to be_valid
      end

      it "rejects nil issue and nil custom_prompt" do
        agent_run = build(:agent_run, issue: nil, custom_prompt: nil)

        expect(agent_run).not_to be_valid
        expect(agent_run.errors[:base]).to include("must have either an issue, a custom prompt, or a source pull request")
      end
    end

    describe "review goal requires pull request" do
      it "is invalid without source_pull_request_number when goal is review" do
        agent_run = build(:agent_run, :review_goal, source_pull_request_number: nil)

        expect(agent_run).not_to be_valid
        expect(agent_run.errors[:source_pull_request_number]).to include("is required for review goals")
      end

      it "is valid with source_pull_request_number when goal is review" do
        agent_run = build(:agent_run, :review_goal)

        expect(agent_run).to be_valid
      end
    end

    describe "enhance_issue goal requires issue" do
      it "is valid when an associated issue is present" do
        project = create(:project)
        issue = create(:issue, project: project)
        agent_run = build(:agent_run, :enhance_issue_goal, project: project, issue: issue)

        expect(agent_run).to be_valid
      end

      it "is invalid without an associated issue" do
        agent_run = build(:agent_run, :enhance_issue_goal, issue: nil, custom_prompt: "Enhance this issue")

        expect(agent_run).not_to be_valid
        expect(agent_run.errors[:issue]).to include("is required for enhance_issue goals")
      end

      it "does not require an issue for create_issue goals" do
        agent_run = build(:agent_run, :create_issue_goal)

        expect(agent_run).to be_valid
      end
    end

    describe "analyze_issue goal requires issue" do
      it "is valid when an associated issue is present" do
        project = create(:project)
        issue = create(:issue, project: project)
        agent_run = build(:agent_run, :analyze_issue_goal, project: project, issue: issue)

        expect(agent_run).to be_valid
      end

      it "is invalid without an associated issue" do
        agent_run = build(:agent_run, :analyze_issue_goal, issue: nil, custom_prompt: "Analyze this issue")

        expect(agent_run).not_to be_valid
        expect(agent_run.errors[:issue]).to include("is required for analyze_issue goals")
      end
    end

    describe "runner ownership validation" do
      it "allows runner from the project owner" do
        agent_run = build(:agent_run)
        runner = create(:runner, user: agent_run.project.effective_owner, runner_key: "opencode")
        agent_run.runner = runner

        expect(agent_run).to be_valid
      end

      it "rejects runner from another user" do
        agent_run = build(:agent_run)
        runner = create(:runner, user: create(:user), runner_key: "opencode")
        agent_run.runner = runner

        expect(agent_run).not_to be_valid
        expect(agent_run.errors[:runner]).to include("must belong to the same user as the project owner")
      end
    end

    describe "external execution fields" do
      it "allows valid external execution rows" do
        project = create(:project, :with_interop_settings)
        agent_run = build(:agent_run, :external_execution, project: project, issue: nil, custom_prompt: "Imported run")

        expect(agent_run).to be_valid
      end

      it "does not require a prompt source for external runs" do
        project = create(:project, :with_interop_settings)
        agent_run = build(:agent_run, :external_execution, project: project, issue: nil, custom_prompt: nil,
          source_pull_request_number: nil)

        expect(agent_run).to be_valid
      end

      it "requires source metadata for external runs" do
        agent_run = build(:agent_run, execution_origin: "external", external_source_key: nil, external_run_key: nil,
          issue: nil, custom_prompt: "Imported run")

        expect(agent_run).not_to be_valid
        expect(agent_run.errors[:external_source_key]).to include("is required for external execution")
        expect(agent_run.errors[:external_run_key]).to include("is required for external execution")
      end

      it "rejects external identifiers on paid-native runs" do
        agent_run = build(:agent_run, external_source_key: "cursor", external_run_key: "run-1",
          issue: nil, custom_prompt: "Native run")

        expect(agent_run).not_to be_valid
        expect(agent_run.errors[:external_source_key]).to include("must be blank for paid-native runs")
      end
    end
  end

  describe "#focused?" do
    it "defaults new runs to general focus" do
      expect(described_class.new.focus).to eq("general")
    end

    it "is false for general runs" do
      expect(build(:agent_run, focus: "general")).not_to be_focused
    end

    it "is true for non-general runs" do
      expect(build(:agent_run, focus: "ci_fix")).to be_focused
    end
  end

  describe "scopes" do
    describe ".by_status" do
      it "returns agent runs with the specified status" do
        running_run = create(:agent_run, :running)
        create(:agent_run, :completed)

        expect(described_class.by_status("running")).to include(running_run)
        expect(described_class.by_status("running").count).to eq(1)
      end
    end

    describe ".claimed" do
      it "returns only claimed (queued with temporal_workflow_id) runs" do
        claimed_run = create(:agent_run, :queued, temporal_workflow_id: "claimed")
        create(:agent_run, :queued)
        create(:agent_run, :running)

        expect(described_class.claimed).to include(claimed_run)
        expect(described_class.claimed.count).to eq(1)
      end
    end

    describe ".running" do
      it "returns only running runs" do
        running_run = create(:agent_run, :running)
        create(:agent_run)

        expect(described_class.running).to include(running_run)
        expect(described_class.running.count).to eq(1)
      end
    end

    describe ".stale_running" do
      it "returns only running runs older than the stale cutoff" do
        stale_run = create(:agent_run, :running, started_at: described_class.stale_running_cutoff - 1.minute)
        create(:agent_run, :running, started_at: described_class.stale_running_cutoff + 1.minute)
        create(:agent_run, :queued, started_at: described_class.stale_running_cutoff - 1.minute)

        expect(described_class.stale_running).to contain_exactly(stale_run)
      end

      it "uses goal-specific adaptive cutoffs when healthy runtime history exists" do
        stub_const("AgentRun::STALE_RUNNING_HEALTHY_MIN_SAMPLE_SIZE", 3)

        create_list(:agent_run, described_class::STALE_RUNNING_HEALTHY_MIN_SAMPLE_SIZE,
          :completed,
          :review_goal,
          duration_seconds: 120,
          completed_at: 1.day.ago)
        create_list(:agent_run, described_class::STALE_RUNNING_HEALTHY_MIN_SAMPLE_SIZE,
          :completed,
          duration_seconds: 900,
          completed_at: 1.day.ago)

        stale_review = create(:agent_run, :running, :review_goal,
          started_at: described_class.stale_running_cutoff(goal: "review") - 1.minute)
        fresh_create_pr = create(:agent_run, :running,
          started_at: described_class.stale_running_cutoff(goal: "create_pr") + 5.minutes)

        expect(described_class.stale_running).to contain_exactly(stale_review)
        expect(described_class.stale_running).not_to include(fresh_create_pr)
        expect(described_class.stale_running_timeout(goal: "review"))
          .to be < described_class.stale_running_timeout(goal: "create_pr")
      end

      it "does not treat completed healthy-history runs as stale running" do
        allow(described_class).to receive(:healthy_successful_runtime_stats_by_goal).and_return(
          "review" => {
            count: described_class::STALE_RUNNING_HEALTHY_MIN_SAMPLE_SIZE,
            p95: 120.0
          }
        )

        stale_review = create(:agent_run, :running, :review_goal,
          started_at: described_class.stale_running_cutoff(goal: "review") - 1.minute)

        expect(described_class.stale_running).to contain_exactly(stale_review)
      end

      it "falls back to the legacy cutoff for unexpected goal values" do
        stale_unknown_goal = create(:agent_run, :running,
          started_at: described_class.stale_running_cutoff - 1.minute)
        stale_unknown_goal.update_column(:goal, "legacy_goal")
        fresh_unknown_goal = create(:agent_run, :running,
          started_at: described_class.stale_running_cutoff + 1.minute)
        fresh_unknown_goal.update_column(:goal, "legacy_goal")

        expect(described_class.stale_running).to include(stale_unknown_goal)
        expect(described_class.stale_running).not_to include(fresh_unknown_goal)
      end
    end

    describe ".stale_claimed" do
      it "returns only claimed runs older than the stale cutoff" do
        stale_run = create(:agent_run, :queued, temporal_workflow_id: "claimed")
        stale_run.update_column(:updated_at, described_class.stale_claimed_cutoff - 1.minute)
        fresh_run = create(:agent_run, :queued, temporal_workflow_id: "claimed")
        fresh_run.update_column(:updated_at, described_class.stale_claimed_cutoff + 1.minute)
        create(:agent_run, :running, started_at: described_class.stale_running_cutoff - 1.minute)

        expect(described_class.stale_claimed).to contain_exactly(stale_run)
      end
    end

    describe ".stale_for_cleanup" do
      it "includes stale running and stale claimed runs" do
        stale_running = create(:agent_run, :running, started_at: described_class.stale_running_cutoff - 1.minute)
        stale_claimed = create(:agent_run, :queued, temporal_workflow_id: "claimed")
        stale_claimed.update_column(:updated_at, described_class.stale_claimed_cutoff - 1.minute)
        create(:agent_run, :running, started_at: described_class.stale_running_cutoff + 1.minute)

        expect(described_class.stale_for_cleanup).to contain_exactly(stale_running, stale_claimed)
      end
    end

    describe ".completed" do
      it "returns only completed runs" do
        completed_run = create(:agent_run, :completed)
        create(:agent_run)

        expect(described_class.completed).to include(completed_run)
        expect(described_class.completed.count).to eq(1)
      end
    end

    describe ".failed" do
      it "returns only failed runs" do
        failed_run = create(:agent_run, :failed)
        create(:agent_run)

        expect(described_class.failed).to include(failed_run)
        expect(described_class.failed.count).to eq(1)
      end
    end

    describe ".cancelled" do
      it "returns only cancelled runs" do
        cancelled_run = create(:agent_run, :cancelled)
        create(:agent_run)

        expect(described_class.cancelled).to include(cancelled_run)
        expect(described_class.cancelled.count).to eq(1)
      end
    end

    describe ".timeout" do
      it "returns only timeout runs" do
        timeout_run = create(:agent_run, :timeout)
        create(:agent_run)

        expect(described_class.timeout).to include(timeout_run)
        expect(described_class.timeout.count).to eq(1)
      end
    end

    describe ".queued" do
      it "returns only queued runs" do
        queued_run = create(:agent_run, :queued)
        create(:agent_run, :running)

        expect(described_class.queued).to include(queued_run)
        expect(described_class.queued.count).to eq(1)
      end
    end

    describe ".retried" do
      it "returns only retried runs" do
        retried_run = create(:agent_run, :retried)
        create(:agent_run)

        expect(described_class.retried).to include(retried_run)
        expect(described_class.retried.count).to eq(1)
      end
    end

    describe ".active" do
      it "includes running runs but not queued or completed" do
        running_run = create(:agent_run, :running)
        create(:agent_run, :completed)
        create(:agent_run, :queued)

        active = described_class.active
        expect(active).to include(running_run)
        expect(active.count).to eq(1)
      end
    end

    describe ".finished" do
      it "includes completed, failed, cancelled, timeout, retried, auth_expired, and rate_limited runs" do
        completed_run = create(:agent_run, :completed)
        failed_run = create(:agent_run, :failed)
        cancelled_run = create(:agent_run, :cancelled)
        timeout_run = create(:agent_run, :timeout)
        retried_run = create(:agent_run, :retried)
        auth_expired_run = create(:agent_run, :auth_expired)
        rate_limited_run = create(:agent_run, :rate_limited)
        create(:agent_run)

        finished = described_class.finished
        expect(finished).to include(completed_run, failed_run, cancelled_run, timeout_run, retried_run, auth_expired_run, rate_limited_run)
        expect(finished.count).to eq(7)
      end
    end

    describe ".rate_limited" do
      it "returns only rate_limited runs" do
        rate_limited_run = create(:agent_run, :rate_limited)
        create(:agent_run)

        expect(described_class.rate_limited).to include(rate_limited_run)
        expect(described_class.rate_limited.count).to eq(1)
      end
    end

    describe ".rate_limited_due" do
      it "returns only rate_limited runs whose recovery window has elapsed" do
        due = create(:agent_run, :rate_limited, rate_limited_until: 1.minute.ago)
        create(:agent_run, :rate_limited, rate_limited_until: 5.minutes.from_now)
        create(:agent_run, :rate_limited, rate_limited_until: nil)

        expect(described_class.rate_limited_due).to contain_exactly(due)
      end
    end

    describe ".auth_expired" do
      it "returns only auth_expired runs" do
        auth_expired_run = create(:agent_run, :auth_expired)
        create(:agent_run)

        expect(described_class.auth_expired).to include(auth_expired_run)
        expect(described_class.auth_expired.count).to eq(1)
      end
    end

    describe ".search_by_goal" do
      it "returns runs with matching custom_prompt (case-insensitive)" do
        matching = create(:agent_run, :with_custom_prompt, custom_prompt: "Fix null byte handling")
        create(:agent_run, :with_custom_prompt, custom_prompt: "Refactor auth module")

        results = described_class.search_by_goal("null byte")

        expect(results).to contain_exactly(matching)
      end

      it "matches partial strings" do
        matching = create(:agent_run, :with_custom_prompt, custom_prompt: "Add user authentication")

        results = described_class.search_by_goal("auth")

        expect(results).to contain_exactly(matching)
      end

      it "is case-insensitive" do
        matching = create(:agent_run, :with_custom_prompt, custom_prompt: "Fix NULL Byte issue")

        results = described_class.search_by_goal("null byte")

        expect(results).to contain_exactly(matching)
      end

      it "matches by goal column value" do
        pr_run = create(:agent_run, goal: "create_pr")
        issue_run = create(:agent_run, goal: "create_issue")

        expect(described_class.search_by_goal("create_pr")).to contain_exactly(pr_run)
        expect(described_class.search_by_goal("create_issue")).to contain_exactly(issue_run)
      end

      it "returns all runs when query is blank" do
        create(:agent_run, :with_custom_prompt, custom_prompt: "Something")
        create(:agent_run, :with_custom_prompt, custom_prompt: "Something else")

        expect(described_class.search_by_goal("").count).to eq(2)
        expect(described_class.search_by_goal(nil).count).to eq(2)
      end
    end

    describe ".recent" do
      it "orders by created_at descending" do
        older_run = create(:agent_run, created_at: 1.hour.ago)
        newer_run = create(:agent_run, created_at: 1.minute.ago)

        expect(described_class.recent.first).to eq(newer_run)
        expect(described_class.recent.last).to eq(older_run)
      end
    end
  end

  describe ".stale_running_timeout" do
    it "falls back to the legacy timeout when healthy history is insufficient" do
      stub_const("AgentRun::STALE_RUNNING_HEALTHY_MIN_SAMPLE_SIZE", 3)
      create_list(:agent_run, described_class::STALE_RUNNING_HEALTHY_MIN_SAMPLE_SIZE - 1,
        :completed,
        :review_goal,
        duration_seconds: 120,
        completed_at: 1.day.ago)

      expect(described_class.stale_running_timeout(goal: "review"))
        .to eq(described_class.default_stale_running_timeout)
    end

    it "uses no_output runs in the healthy baseline" do
      stub_const("AgentRun::STALE_RUNNING_HEALTHY_MIN_SAMPLE_SIZE", 3)
      create_list(:agent_run, described_class::STALE_RUNNING_HEALTHY_MIN_SAMPLE_SIZE,
        :no_output,
        :review_goal,
        duration_seconds: 120,
        completed_at: 1.day.ago,
        error_message: "no_changes")

      expect(described_class.stale_running_timeout(goal: "review"))
        .to eq(20.minutes)
    end
  end

  describe "instance methods" do
    describe "#duration" do
      it "returns nil when started_at is nil" do
        agent_run = build(:agent_run, started_at: nil)

        expect(agent_run.duration).to be_nil
      end

      it "returns seconds between started_at and completed_at" do
        agent_run = build(:agent_run, started_at: 10.minutes.ago, completed_at: 5.minutes.ago)

        expect(agent_run.duration).to be_within(1).of(300)
      end

      it "returns seconds from started_at to now when not completed" do
        agent_run = build(:agent_run, started_at: 5.minutes.ago, completed_at: nil)

        expect(agent_run.duration).to be_within(1).of(300)
      end

      it "returns 0 instead of negative when completed_at is before started_at" do
        agent_run = build(:agent_run, started_at: Time.current, completed_at: 1.hour.ago)

        expect(agent_run.duration).to eq(0)
      end
    end

    describe "#create_issue_goal?" do
      it "returns true when goal is create_issue" do
        agent_run = build(:agent_run, goal: "create_issue")

        expect(agent_run.create_issue_goal?).to be true
      end

      it "returns false when goal is create_pr" do
        agent_run = build(:agent_run, goal: "create_pr")

        expect(agent_run.create_issue_goal?).to be false
      end
    end

    describe "#result_url" do
      it "returns pull_request_url when present" do
        agent_run = build(:agent_run, pull_request_url: "https://github.com/example/repo/pull/1")

        expect(agent_run.result_url).to eq("https://github.com/example/repo/pull/1")
      end

      it "returns created_issue_url when no PR url" do
        agent_run = build(:agent_run, pull_request_url: nil, created_issue_url: "https://github.com/example/repo/issues/5")

        expect(agent_run.result_url).to eq("https://github.com/example/repo/issues/5")
      end

      it "returns nil when neither is present" do
        agent_run = build(:agent_run, pull_request_url: nil, created_issue_url: nil)

        expect(agent_run.result_url).to be_nil
      end
    end

    describe "#manual?" do
      it "returns true when trigger_type is manual" do
        agent_run = build(:agent_run, trigger_type: "manual")

        expect(agent_run.manual?).to be true
      end

      it "returns false when trigger_type is automatic" do
        agent_run = build(:agent_run, trigger_type: "automatic")

        expect(agent_run.manual?).to be false
      end
    end

    describe "#automatic?" do
      it "returns true when trigger_type is automatic" do
        agent_run = build(:agent_run, trigger_type: "automatic")

        expect(agent_run.automatic?).to be true
      end

      it "returns false when trigger_type is manual" do
        agent_run = build(:agent_run, trigger_type: "manual")

        expect(agent_run.automatic?).to be false
      end
    end

    describe "#queued?" do
      it "returns true when status is queued" do
        agent_run = build(:agent_run, :queued)

        expect(agent_run.queued?).to be true
      end

      it "returns false when status is not queued" do
        agent_run = build(:agent_run, :running)

        expect(agent_run.queued?).to be false
      end
    end

    describe "#active?" do
      it "returns true for running status" do
        expect(build(:agent_run, :running).active?).to be true
      end

      it "returns false for queued status" do
        expect(build(:agent_run, :queued).active?).to be false
      end

      it "returns false for completed status" do
        expect(build(:agent_run, :completed).active?).to be false
      end

      it "returns false for failed status" do
        expect(build(:agent_run, :failed).active?).to be false
      end
    end

    describe "#running?" do
      it "returns true when status is running" do
        agent_run = build(:agent_run, :running)

        expect(agent_run.running?).to be true
      end

      it "returns false when status is not running" do
        agent_run = build(:agent_run)

        expect(agent_run.running?).to be false
      end
    end

    describe "#finished?" do
      it "returns true for completed status" do
        expect(build(:agent_run, :completed).finished?).to be true
      end

      it "returns true for failed status" do
        expect(build(:agent_run, :failed).finished?).to be true
      end

      it "returns true for cancelled status" do
        expect(build(:agent_run, :cancelled).finished?).to be true
      end

      it "returns true for timeout status" do
        expect(build(:agent_run, :timeout).finished?).to be true
      end

      it "returns true for retried status" do
        expect(build(:agent_run, :retried).finished?).to be true
      end

      it "returns true for auth_expired status" do
        expect(build(:agent_run, :auth_expired).finished?).to be true
      end

      it "returns true for rate_limited status" do
        expect(build(:agent_run, :rate_limited).finished?).to be true
      end

      it "returns false for queued status" do
        expect(build(:agent_run, :queued).finished?).to be false
      end

      it "returns false for running status" do
        expect(build(:agent_run, :running).finished?).to be false
      end
    end

    describe "#retried?" do
      it "returns true when status is retried" do
        agent_run = build(:agent_run, :retried)

        expect(agent_run.retried?).to be true
      end

      it "returns false when status is not retried" do
        agent_run = build(:agent_run, :failed)

        expect(agent_run.retried?).to be false
      end
    end

    describe "#successful?" do
      it "returns true when status is completed" do
        agent_run = build(:agent_run, :completed)

        expect(agent_run.successful?).to be true
      end

      it "returns false when status is not completed" do
        agent_run = build(:agent_run, :failed)

        expect(agent_run.successful?).to be false
      end
    end

    describe "#cancelled_by_cleanup?" do
      it "returns true when status is timeout and error_message starts with the dev:cleanup sentinel prefix" do
        agent_run = build(:agent_run, status: "timeout",
          error_message: "#{AgentRun::STALE_CLEANUP_ERROR_PREFIX}: process was restarted")

        expect(agent_run.cancelled_by_cleanup?).to be true
      end

      it "returns true when status is timeout and error_message starts with the stale detector prefix" do
        agent_run = build(:agent_run, status: "timeout",
          error_message: "#{AgentRun::STALE_DETECTOR_ERROR_PREFIX}: stuck in 'running' beyond timeout threshold")

        expect(agent_run.cancelled_by_cleanup?).to be true
      end

      it "returns false when error_message lacks both sentinel prefixes" do
        agent_run = build(:agent_run, status: "timeout", error_message: "Runner timed out")

        expect(agent_run.cancelled_by_cleanup?).to be false
      end

      it "returns false when status is not timeout even if the prefix is present" do
        agent_run = build(:agent_run, :failed,
          error_message: "#{AgentRun::STALE_CLEANUP_ERROR_PREFIX}: process was restarted")

        expect(agent_run.cancelled_by_cleanup?).to be false
      end

      it "returns false when error_message is nil" do
        agent_run = build(:agent_run, status: "timeout", error_message: nil)

        expect(agent_run.cancelled_by_cleanup?).to be false
      end
    end

    describe "#operational_failure?" do
      it "returns true for timeout status" do
        agent_run = build(:agent_run, :timeout, error_message: "wall_clock_timeout: exceeded 30 minutes")

        expect(agent_run.operational_failure?).to be true
      end

      it "returns true for auth_expired status" do
        agent_run = build(:agent_run, :auth_expired)

        expect(agent_run.operational_failure?).to be true
      end

      it "returns true for rate_limited status" do
        agent_run = build(:agent_run, :rate_limited)

        expect(agent_run.operational_failure?).to be true
      end

      it "returns true for token_budget_exceeded status" do
        agent_run = build(:agent_run, status: "token_budget_exceeded")

        expect(agent_run.operational_failure?).to be true
      end

      it "returns true for failed status with runner exhaustion error" do
        agent_run = build(:agent_run, :failed,
          error_message: "All providers exhausted: claude_code, codex")

        expect(agent_run.operational_failure?).to be true
      end

      it "returns true for failed status with Docker exec error" do
        agent_run = build(:agent_run, :failed,
          error_message: "Docker exec error: {\"message\":\"container abc123...\"}")

        expect(agent_run.operational_failure?).to be true
      end

      it "returns true for failed status with worktree conflict" do
        agent_run = build(:agent_run, :failed,
          error_message: "Branch fix/foo has an active worktree from agent run 1234")

        expect(agent_run.operational_failure?).to be true
      end

      it "returns true for failed status with Clone failed" do
        agent_run = build(:agent_run, :failed,
          error_message: "Clone failed: could not resolve host")

        expect(agent_run.operational_failure?).to be true
      end

      it "returns false for failed status with agent exit code error" do
        agent_run = build(:agent_run, :failed,
          error_message: "Agent exited with code 1: compilation failed")

        expect(agent_run.operational_failure?).to be false
      end

      it "returns false for failed status with review posting failure" do
        agent_run = build(:agent_run, :failed,
          error_message: "No tracked review for PR #1234 and no GitHub review exists.")

        expect(agent_run.operational_failure?).to be false
      end

      it "returns false for completed status" do
        agent_run = build(:agent_run, :completed)

        expect(agent_run.operational_failure?).to be false
      end

      it "returns false for no_output status" do
        agent_run = build(:agent_run, :no_output)

        expect(agent_run.operational_failure?).to be false
      end

      it "returns false for failed status with nil error message" do
        agent_run = build(:agent_run, :failed, error_message: nil)

        expect(agent_run.operational_failure?).to be false
      end
    end

    describe "#provider_unavailable?" do
      it "returns true for rate_limited status" do
        agent_run = build(:agent_run, :rate_limited)

        expect(agent_run.provider_unavailable?).to be true
      end

      it "returns true for failed status with providers exhausted error" do
        agent_run = build(:agent_run, :failed,
          error_message: "All providers exhausted: claude_code, codex")

        expect(agent_run.provider_unavailable?).to be true
      end

      it "returns true for failed status with runners exhausted error" do
        agent_run = build(:agent_run, :failed,
          error_message: "All runners exhausted: no capacity available")

        expect(agent_run.provider_unavailable?).to be true
      end

      it "returns false for timeout status (non-provider task timeout)" do
        agent_run = build(:agent_run, :timeout,
          error_message: "wall_clock_timeout: exceeded 30 minutes")

        expect(agent_run.provider_unavailable?).to be false
      end

      it "returns false for auth_expired status" do
        agent_run = build(:agent_run, :auth_expired)

        expect(agent_run.provider_unavailable?).to be false
      end

      it "returns false for failed status with agent code error" do
        agent_run = build(:agent_run, :failed,
          error_message: "Agent exited with code 1: compilation failed")

        expect(agent_run.provider_unavailable?).to be false
      end

      it "returns false for failed status with worktree error" do
        agent_run = build(:agent_run, :failed,
          error_message: "Branch fix/foo has an active worktree from agent run 1234")

        expect(agent_run.provider_unavailable?).to be false
      end
    end

    describe "#pre_runner_infra_failure?" do
      it "returns true for Docker pull failure with zero tokens and no runner" do
        agent_run = build(:agent_run, :failed,
          error_message: "Failed to start service container postgres: Failed to pull image postgres:16.13: Bad Gateway",
          tokens_input: 0, final_runner: nil)

        expect(agent_run.pre_runner_infra_failure?).to be true
      end

      it "returns true for DNS resolution failure" do
        agent_run = build(:agent_run, :failed,
          error_message: "Failed to open TCP connection to api.github.com:443 (getaddrinfo: Temporary failure in name resolution)",
          tokens_input: 0, final_runner: nil)

        expect(agent_run.pre_runner_infra_failure?).to be true
      end

      it "returns true for PG connection slot exhaustion" do
        agent_run = build(:agent_run, :failed,
          error_message: "connection slots are reserved for roles with the SUPERUSER attribute",
          tokens_input: 0, final_runner: nil)

        expect(agent_run.pre_runner_infra_failure?).to be true
      end

      it "returns false when tokens were consumed (runner was reached)" do
        agent_run = build(:agent_run, :failed,
          error_message: "Failed to start service container postgres: Failed to pull image postgres:16",
          tokens_input: 500, final_runner: nil)

        expect(agent_run.pre_runner_infra_failure?).to be false
      end

      it "returns false when final_runner is present" do
        agent_run = build(:agent_run, :failed,
          error_message: "Failed to start service container postgres: Failed to pull image postgres:16",
          tokens_input: 0, final_runner: "claude")

        expect(agent_run.pre_runner_infra_failure?).to be false
      end

      it "returns false for runner exhaustion error (runner was attempted)" do
        agent_run = build(:agent_run, :failed,
          error_message: "All runners exhausted: Claude, Codex",
          tokens_input: 0, final_runner: nil)

        expect(agent_run.pre_runner_infra_failure?).to be false
      end

      it "returns false for non-failed status" do
        agent_run = build(:agent_run, :completed,
          error_message: "Failed to pull image postgres:16",
          tokens_input: 0, final_runner: nil)

        expect(agent_run.pre_runner_infra_failure?).to be false
      end
    end

    describe "#push_permission_rejection?" do
      let(:rejection_error) do
        "Push failed: Command exited with code 1 — ! [remote rejected] " \
          "paid/2368-branch -> paid/2368-branch (refusing to allow a GitHub App " \
          "to create or update workflow `.github/workflows/mutation.yml` without " \
          "`workflows` permission)"
      end

      it "returns true for a workflows permission push rejection" do
        agent_run = build(:agent_run, :failed, error_message: rejection_error)

        expect(agent_run.push_permission_rejection?).to be true
      end

      it "returns true for the without `workflows` permission phrase alone" do
        agent_run = build(:agent_run, :failed,
          error_message: "Push failed: rejected without `workflows` permission")

        expect(agent_run.push_permission_rejection?).to be true
      end

      it "returns false for a generic push failure" do
        agent_run = build(:agent_run, :failed,
          error_message: "Push failed: non-fast-forward update")

        expect(agent_run.push_permission_rejection?).to be false
      end

      it "returns false for a non-failed status" do
        agent_run = build(:agent_run, :completed, error_message: rejection_error)

        expect(agent_run.push_permission_rejection?).to be false
      end
    end

    describe "#operational_failure? excludes pre-runner infra failures" do
      it "returns false for Docker pull failure (pre-runner infra)" do
        agent_run = build(:agent_run, :failed,
          error_message: "Failed to start service container postgres: Failed to pull image postgres:16.13: Bad Gateway",
          tokens_input: 0, final_runner: nil)

        expect(agent_run.operational_failure?).to be false
      end

      it "returns false for DNS failure (pre-runner infra)" do
        agent_run = build(:agent_run, :failed,
          error_message: "Failed to open TCP connection to api.github.com:443 (getaddrinfo: Temporary failure in name resolution)",
          tokens_input: 0, final_runner: nil)

        expect(agent_run.operational_failure?).to be false
      end

      it "still returns true for Docker exec error during agent execution" do
        agent_run = build(:agent_run, :failed,
          error_message: "Docker exec error: container abc123 is not running",
          tokens_input: 500, final_runner: "claude")

        expect(agent_run.operational_failure?).to be true
      end

      it "still returns true for runner exhaustion" do
        agent_run = build(:agent_run, :failed,
          error_message: "All runners exhausted: Claude, Codex",
          tokens_input: 0, final_runner: nil)

        expect(agent_run.operational_failure?).to be true
      end
    end

    describe "#infra_failure?" do
      it "returns true for failed run with validation error and zero tokens" do
        agent_run = build(:agent_run, :failed,
          error_message: "Validation failed: Review settings paid_agent requires credentials",
          tokens_input: 0)

        expect(agent_run.infra_failure?).to be true
      end

      it "returns true for failed run with ProviderAuthExpiredError and zero tokens" do
        agent_run = build(:agent_run, :failed,
          error_message: "ProviderAuthExpiredError: token expired",
          tokens_input: 0)

        expect(agent_run.infra_failure?).to be true
      end

      it "returns true for no_output run with Provision::TimeoutError and zero tokens" do
        agent_run = build(:agent_run, :no_output,
          error_message: "Containers::Provision::TimeoutError: startup timed out",
          tokens_input: 0)

        expect(agent_run.infra_failure?).to be true
      end

      it "returns false for failed run with infra keyword but non-zero tokens" do
        agent_run = build(:agent_run, :failed,
          error_message: "Validation failed: something after model ran",
          tokens_input: 5000)

        expect(agent_run.infra_failure?).to be false
      end

      it "returns false for completed run" do
        agent_run = build(:agent_run, :completed,
          error_message: "Validation failed: something",
          tokens_input: 0)

        expect(agent_run.infra_failure?).to be false
      end

      it "returns true for case-insensitive match on infra keyword" do
        agent_run = build(:agent_run, :failed,
          error_message: "validation failed: review settings paid_agent requires credentials",
          tokens_input: 0)

        expect(agent_run.infra_failure?).to be true
      end

      it "returns false for failed run without infra keyword" do
        agent_run = build(:agent_run, :failed,
          error_message: "Agent exited with code 1",
          tokens_input: 0)

        expect(agent_run.infra_failure?).to be false
      end

      it "returns false for nil tokens_input without infra keyword" do
        agent_run = build(:agent_run, :failed,
          error_message: "Agent exited with code 1",
          tokens_input: nil)

        expect(agent_run.infra_failure?).to be false
      end
    end

    describe "#total_tokens" do
      it "returns sum of input and output tokens" do
        agent_run = build(:agent_run, tokens_input: 1000, tokens_output: 500)

        expect(agent_run.total_tokens).to eq(1500)
      end
    end

    describe "#token_limit_exceeded?" do
      it "returns true when token_limit_status is exceeded" do
        agent_run = build(:agent_run, token_limit_status: "exceeded")
        expect(agent_run.token_limit_exceeded?).to be true
      end

      it "returns false when token_limit_status is warning" do
        agent_run = build(:agent_run, token_limit_status: "warning")
        expect(agent_run.token_limit_exceeded?).to be false
      end
    end

    describe "#token_limit_warning?" do
      it "returns true when token_limit_status is warning" do
        agent_run = build(:agent_run, token_limit_status: "warning")
        expect(agent_run.token_limit_warning?).to be true
      end
    end

    describe "#effective_max_tokens_per_run" do
      it "returns the project override when set" do
        project = create(:project, max_tokens_per_run: 500_000)
        agent_run = build(:agent_run, project: project)

        expect(agent_run.effective_max_tokens_per_run).to eq(500_000)
      end

      it "uses an explicit user setting override when the project has none" do
        project = create(:project, max_tokens_per_run: nil)
        project.created_by.settings.update!(max_tokens_per_run: 750_000)
        agent_run = build(:agent_run, project: project)

        expect(agent_run.effective_max_tokens_per_run).to eq(750_000)
      end

      it "falls back to the account default when the user setting is just the inherited global default" do
        project = create(:project, max_tokens_per_run: nil)
        project.account.update!(default_max_tokens_per_run: 2_000_000)
        project.created_by.settings
        agent_run = build(:agent_run, project: project)

        expect(agent_run.effective_max_tokens_per_run).to eq(2_000_000)
      end

      it "preserves an explicit user override at the global default value" do
        project = create(:project, max_tokens_per_run: nil)
        project.account.update!(default_max_tokens_per_run: 2_000_000)
        user_setting = project.created_by.settings
        user_setting.update!(default_branch: "develop", max_tokens_per_run: AgentRun::DEFAULT_MAX_TOKENS_PER_RUN)
        agent_run = build(:agent_run, project: project)

        expect(agent_run.effective_max_tokens_per_run).to eq(AgentRun::DEFAULT_MAX_TOKENS_PER_RUN)
      end

      it "caps the resolved token limit with the tenant guardrail" do
        project = create(:project, max_tokens_per_run: 500_000)
        create(:tenant_setting, account: project.account, guardrails: { "max_tokens_per_run" => 100_000 })
        agent_run = build(:agent_run, project: project)

        expect(agent_run.effective_max_tokens_per_run).to eq(100_000)
      end
    end

    describe "#effective_token_budget" do
      it "uses the project-level budget override when set" do
        project = create(:project, token_budget_max_input_tokens: 250_000)
        agent_run = build(:agent_run, project: project)

        expect(agent_run.effective_token_budget).to eq(250_000)
      end

      it "falls back to the provider (runner) threshold when no project override is set" do
        project = create(:project)
        runner = create(:runner, user: project.created_by, no_progress_thresholds: { "min_input_tokens" => 50_000, "max_output_tokens" => 25 })
        agent_run = build(:agent_run, project: project, runner: runner)

        expect(agent_run.effective_token_budget).to eq(50_000)
        expect(agent_run.effective_token_budget_progress_floor).to eq(25)
      end

      it "falls back to the global default when neither project nor runner is configured" do
        project = create(:project)
        agent_run = build(:agent_run, project: project, runner: nil)

        expect(agent_run.effective_token_budget).to eq(Runner::DEFAULT_NO_PROGRESS_THRESHOLDS.fetch("min_input_tokens"))
        expect(agent_run.effective_token_budget_progress_floor).to eq(Runner::DEFAULT_NO_PROGRESS_THRESHOLDS.fetch("max_output_tokens"))
      end

      it "prefers the project budget over the runner threshold" do
        project = create(:project, token_budget_max_input_tokens: 300_000)
        runner = create(:runner, user: project.created_by, no_progress_thresholds: { "min_input_tokens" => 50_000 })
        agent_run = build(:agent_run, project: project, runner: runner)

        expect(agent_run.effective_token_budget).to eq(300_000)
      end
    end

    describe "#token_budget_exceeded?" do
      it "returns true when the status is token_budget_exceeded" do
        agent_run = build(:agent_run, status: "token_budget_exceeded")

        expect(agent_run).to be_token_budget_exceeded
      end

      it "returns false for other statuses" do
        agent_run = build(:agent_run, status: "running")

        expect(agent_run).not_to be_token_budget_exceeded
      end
    end

    describe "#effective_max_execution_seconds" do
      it "returns the user override when set" do
        project = create(:project, max_execution_seconds: 900)
        project.created_by.settings.update!(max_execution_seconds: 1800)
        agent_run = build(:agent_run, project: project)

        expect(agent_run.effective_max_execution_seconds).to eq(1800)
      end

      it "falls back to the project setting when the user override is nil" do
        project = create(:project, max_execution_seconds: 900)
        project.created_by.settings.update!(max_execution_seconds: nil)
        agent_run = build(:agent_run, project: project)

        expect(agent_run.effective_max_execution_seconds).to eq(900)
      end
    end

    describe "#token_limit_usage_ratio" do
      it "returns the ratio of tokens used to limit" do
        project = build(:project, max_tokens_per_run: 1_000_000)
        agent_run =
          build(:agent_run, project: project, tokens_input: 400_000, tokens_output: 100_000)

        expect(agent_run.token_limit_usage_ratio).to eq(0.5)
      end
    end

    describe "#start!" do
      it "sets status to running and sets started_at" do
        agent_run = create(:agent_run)

        freeze_time do
          agent_run.start!

          expect(agent_run.status).to eq("running")
          expect(agent_run.started_at).to eq(Time.current)
        end
      end

      it "raises when the run is already finished" do
        agent_run = create(:agent_run, :failed)

        expect { agent_run.start! }.to raise_error(ActiveRecord::RecordInvalid, /cannot start a finished agent run/)
        expect(agent_run.reload.status).to eq("failed")
      end

      it "clears stale completed_at to prevent negative duration" do
        agent_run = create(:agent_run, :queued, completed_at: 1.hour.ago)

        agent_run.start!

        expect(agent_run.completed_at).to be_nil
      end
    end

    describe "#complete!" do
      it "sets status to completed with results and duration", :aggregate_failures do
        started_time = 10.minutes.ago
        agent_run = create(:agent_run, status: "running", started_at: started_time)

        freeze_time do
          agent_run.complete!(
            result_commit: "abc123",
            pr_url: "https://github.com/example/repo/pull/42",
            pr_number: 42
          )

          expect(agent_run.status).to eq("completed")
          expect(agent_run.completed_at).to eq(Time.current)
          expect(agent_run.result_commit_sha).to eq("abc123")
          expect(agent_run.pull_request_url).to eq("https://github.com/example/repo/pull/42")
          expect(agent_run.pull_request_number).to eq(42)
          expect(agent_run.duration_seconds).to eq((Time.current - started_time).to_i)
        end
      end

      it "does not overwrite a cancelled run" do
        agent_run = create(:agent_run, :cancelled, pull_request_url: nil, pull_request_number: nil)

        expect(
          agent_run.complete!(pr_url: "https://github.com/example/repo/pull/42", pr_number: 42)
        ).to be false

        expect(agent_run.reload.status).to eq("cancelled")
        expect(agent_run.pull_request_url).to be_nil
        expect(agent_run.pull_request_number).to be_nil
      end
    end

    describe "#complete! with issue details" do
      it "sets created_issue_url and created_issue_number", :aggregate_failures do
        agent_run = create(:agent_run, status: "running", started_at: 5.minutes.ago, goal: "create_issue")

        freeze_time do
          agent_run.complete!(
            issue_url: "https://github.com/example/repo/issues/10",
            issue_number: 10
          )

          expect(agent_run.status).to eq("completed")
          expect(agent_run.created_issue_url).to eq("https://github.com/example/repo/issues/10")
          expect(agent_run.created_issue_number).to eq(10)
          expect(agent_run.pull_request_url).to be_nil
        end
      end
    end

    describe "#complete_no_output!" do
      it "does not overwrite a cancelled run" do
        agent_run = create(:agent_run, :cancelled, error_message: nil)

        expect(agent_run.complete_no_output!(reason: "no_changes")).to be false

        expect(agent_run.reload.status).to eq("cancelled")
        expect(agent_run.error_message).to be_nil
      end
    end

    describe "#fail!" do
      it "sets status to failed with error message and duration" do
        started_time = 10.minutes.ago
        agent_run = create(:agent_run, status: "running", started_at: started_time)

        freeze_time do
          agent_run.fail!(error: "Something went wrong")

          expect(agent_run.status).to eq("failed")
          expect(agent_run.completed_at).to eq(Time.current)
          expect(agent_run.error_message).to eq("Something went wrong")
          expect(agent_run.duration_seconds).to eq((Time.current - started_time).to_i)
        end
      end

      it "does not overwrite a finished run", :aggregate_failures do
        completed_at = 10.minutes.ago
        agent_run = create(:agent_run, :completed,
          completed_at: completed_at,
          duration_seconds: 25,
          error_message: nil)

        expect(agent_run.fail!(error: "Late failure")).to be false

        agent_run.reload
        expect(agent_run.status).to eq("completed")
        expect(agent_run.completed_at).to be_within(1.second).of(completed_at)
        expect(agent_run.duration_seconds).to eq(25)
        expect(agent_run.error_message).to be_nil
      end
    end

    describe "#cancel!" do
      it "sets status to cancelled with duration" do
        started_time = 5.minutes.ago
        agent_run = create(:agent_run, status: "running", started_at: started_time)

        freeze_time do
          agent_run.cancel!

          expect(agent_run.status).to eq("cancelled")
          expect(agent_run.completed_at).to eq(Time.current)
          expect(agent_run.duration_seconds).to eq((Time.current - started_time).to_i)
        end
      end

      it "does not overwrite a finished run", :aggregate_failures do
        completed_at = 10.minutes.ago
        agent_run = create(:agent_run, :completed,
          completed_at: completed_at,
          duration_seconds: 25)

        expect(agent_run.cancel!).to be false

        agent_run.reload
        expect(agent_run.status).to eq("completed")
        expect(agent_run.completed_at).to be_within(1.second).of(completed_at)
        expect(agent_run.duration_seconds).to eq(25)
      end
    end

    describe "#timeout!" do
      it "sets status to timeout with duration" do
        started_time = 1.hour.ago
        agent_run = create(:agent_run, status: "running", started_at: started_time)

        freeze_time do
          agent_run.timeout!

          expect(agent_run.status).to eq("timeout")
          expect(agent_run.completed_at).to eq(Time.current)
          expect(agent_run.duration_seconds).to eq((Time.current - started_time).to_i)
        end
      end

      it "can persist guardrail metadata atomically" do
        agent_run = create(:agent_run, :running)
        context = { violation_type: "time_limit", details: "Execution exceeded 3600s limit" }

        agent_run.timeout!(
          error: "guardrail: time_limit — Execution exceeded 3600s limit",
          guardrail_violation_type: "time_limit",
          guardrail_context: context
        )

        agent_run.reload
        expect(agent_run.status).to eq("timeout")
        expect(agent_run.guardrail_violation_type).to eq("time_limit")
        expect(agent_run.guardrail_context).to eq(context.deep_stringify_keys)
      end

      it "does not overwrite a finished run", :aggregate_failures do
        completed_at = 10.minutes.ago
        agent_run = create(:agent_run, :completed,
          completed_at: completed_at,
          duration_seconds: 25,
          error_message: nil)

        expect(agent_run.timeout!(error: "Stale run detected")).to be false

        agent_run.reload
        expect(agent_run.status).to eq("completed")
        expect(agent_run.completed_at).to be_within(1.second).of(completed_at)
        expect(agent_run.duration_seconds).to eq(25)
        expect(agent_run.error_message).to be_nil
      end
    end

    describe "#retry!" do
      it "sets status to retried" do
        agent_run = create(:agent_run, :failed)

        agent_run.retry!

        expect(agent_run.status).to eq("retried")
      end

      it "records a retry decision event" do
        agent_run = create(:agent_run, :failed)

        expect {
          agent_run.retry!(decision_point: "manual_retry", result: { new_agent_run_id: 123 })
        }.to change(OrchestrationDecision, :count).by(1)

        event = OrchestrationDecision.last
        expect(event.decision_type).to eq("retry")
        expect(event.context["decision_status"]).to eq("applied")
        expect(event.actor).to eq("manual_retry")
        expect(event.outputs).to include("new_agent_run_id" => 123, "status" => "retried")
      end

      it "still marks the run retried when decision logging fails" do
        agent_run = create(:agent_run, :failed)
        allow(OrchestrationDecision).to receive(:record!).and_raise(ActiveRecord::StatementInvalid, "boom")

        expect { agent_run.retry! }.not_to raise_error

        expect(agent_run.reload.status).to eq("retried")
      end
    end

    describe "#auth_expired?" do
      it "returns true when status is auth_expired" do
        agent_run = build(:agent_run, :auth_expired)

        expect(agent_run.auth_expired?).to be true
      end

      it "returns false when status is not auth_expired" do
        agent_run = build(:agent_run, :failed)

        expect(agent_run.auth_expired?).to be false
      end
    end

    describe "#auth_expire!" do
      it "sets status to auth_expired with error and runner" do
        started_time = 10.minutes.ago
        agent_run = create(:agent_run, status: "running", started_at: started_time)

        freeze_time do
          agent_run.auth_expire!(error: "OAuth session expired", runner: "claude")

          expect(agent_run.status).to eq("auth_expired")
          expect(agent_run.completed_at).to eq(Time.current)
          expect(agent_run.error_message).to eq("OAuth session expired")
          expect(agent_run.auth_provider).to eq("claude")
          expect(agent_run.duration_seconds).to eq((Time.current - started_time).to_i)
        end
      end
    end

    describe "#rate_limited?" do
      it "returns true when status is rate_limited" do
        agent_run = build(:agent_run, :rate_limited)

        expect(agent_run.rate_limited?).to be true
      end

      it "returns false when status is not rate_limited" do
        agent_run = build(:agent_run, :failed)

        expect(agent_run.rate_limited?).to be false
      end
    end

    describe "#recoverable_rate_limited?" do
      it "is true for a rate_limited run with a recovery time set" do
        agent_run = build(:agent_run, :rate_limited, rate_limited_until: 2.minutes.from_now)

        expect(agent_run.recoverable_rate_limited?).to be true
      end

      it "is false for a rate_limited run without a recovery time" do
        agent_run = build(:agent_run, :rate_limited, rate_limited_until: nil)

        expect(agent_run.recoverable_rate_limited?).to be false
      end

      it "is false for a failed run" do
        agent_run = build(:agent_run, :failed)

        expect(agent_run.recoverable_rate_limited?).to be false
      end
    end

    describe "#container_retained?" do
      it "returns true when retention TTL is in the future" do
        agent_run = build(:agent_run, container_retained_until: 2.hours.from_now)

        expect(agent_run.container_retained?).to be true
      end

      it "returns false when retention TTL is in the past" do
        agent_run = build(:agent_run, container_retained_until: 1.hour.ago)

        expect(agent_run.container_retained?).to be false
      end

      it "returns false when retention TTL is nil" do
        agent_run = build(:agent_run, container_retained_until: nil)

        expect(agent_run.container_retained?).to be false
      end
    end

    describe "#rate_limit!" do
      it "sets status to rate_limited with error and reset time" do
        freeze_time do
          started_time = 10.minutes.ago
          agent_run = create(:agent_run, status: "running", started_at: started_time)
          reset_at = 2.hours.from_now

          agent_run.rate_limit!(error: "All providers rate limited", reset_at: reset_at)

          expect(agent_run.status).to eq("rate_limited")
          expect(agent_run.completed_at).to eq(Time.current)
          expect(agent_run.error_message).to eq("All providers rate limited")
          expect(agent_run.rate_limited_until).to be_within(1.second).of(reset_at)
          expect(agent_run.duration_seconds).to eq((Time.current - started_time).to_i)
        end
      end
    end

    describe "#log!" do
      it "creates an agent_run_log with the given type and content" do
        agent_run = create(:agent_run)

        expect {
          agent_run.log!("stdout", "Hello world")
        }.to change(AgentRunLog, :count).by(1)

        log = agent_run.agent_run_logs.last
        expect(log.log_type).to eq("stdout")
        expect(log.content).to eq("Hello world")
        expect(log.metadata).to be_nil
      end

      it "stores optional metadata as JSON" do
        agent_run = create(:agent_run)

        agent_run.log!("system", "container.started", metadata: { container_id: "abc123", image: "paid-agent:latest" })

        log = agent_run.agent_run_logs.last
        expect(log.metadata).to eq({ "container_id" => "abc123", "image" => "paid-agent:latest" })
      end

      it "returns the created log entry" do
        agent_run = create(:agent_run)

        log = agent_run.log!("stderr", "Error message")

        expect(log).to be_a(AgentRunLog)
        expect(log).to be_persisted
      end

      it "scrubs invalid UTF-8 content before persisting" do
        agent_run = create(:agent_run)

        log = agent_run.log!("stdout", "bad \xFF output".b)

        expect(log.content).to eq("bad � output")
        expect(log.content.encoding).to eq(Encoding::UTF_8)
        expect(log.content).to be_valid_encoding
      end

      it "raises error for invalid log type" do
        agent_run = create(:agent_run)

        expect {
          agent_run.log!("invalid_type", "content")
        }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    describe "#execute_agent" do
      let(:response) do
        AgentHarness::Response.new(
          output: "Done",
          exit_code: 0,
          duration: 10.0,
          provider: :claude
        )
      end

      before do
        allow(AgentHarness).to receive(:send_message).and_return(response)
      end

      it "delegates to AgentRuns::Execute without timeout by default" do
        agent_run = create(:agent_run)

        expect(AgentRuns::Execute).to receive(:call).with(
          agent_run: agent_run,
          prompt: "Fix the bug"
        ).and_call_original

        agent_run.execute_agent("Fix the bug")
      end

      it "passes custom timeout when provided" do
        agent_run = create(:agent_run)

        expect(AgentRuns::Execute).to receive(:call).with(
          agent_run: agent_run,
          prompt: "Fix it",
          timeout: 1200
        ).and_call_original

        agent_run.execute_agent("Fix it", timeout: 1200)
      end
    end

    describe "#prompt_for_issue" do
      it "returns nil when no issue is attached" do
        agent_run = build(:agent_run, issue: nil)

        expect(agent_run.prompt_for_issue).to be_nil
      end

      it "builds a prompt when issue is attached and trusted" do
        project = create(:project, allowed_github_usernames: [ "viamin" ])
        issue = create(:issue, project: project, title: "Fix auth", github_number: 5, github_creator_login: "viamin")
        agent_run = build(:agent_run, project: project, issue: issue)
        github_client = instance_double(GithubClient, issue_comments: [])
        allow(project.github_token).to receive(:client).and_return(github_client)

        prompt = agent_run.prompt_for_issue

        expect(prompt).to include("Fix auth")
        expect(prompt).to include("#5")
      end

      it "raises when issue is from an untrusted user" do
        project = create(:project, allowed_github_usernames: [ "viamin" ])
        issue = create(:issue, project: project, title: "Malicious", github_number: 666, github_creator_login: "attacker")
        agent_run = build(:agent_run, project: project, issue: issue)

        expect {
          agent_run.prompt_for_issue
        }.to raise_error(Prompts::BuildForIssue::UntrustedIssueError, /attacker/)
      end
    end

    describe "#ensure_proxy_token!" do
      it "returns the existing token when present" do
        agent_run = create(:agent_run)
        original_token = agent_run.proxy_token

        expect(original_token).to be_present
        expect(agent_run.ensure_proxy_token!).to eq(original_token)
      end

      it "generates and persists a token when proxy_token is nil" do
        agent_run = create(:agent_run)
        agent_run.update_column(:proxy_token, nil)
        agent_run.reload

        token = agent_run.ensure_proxy_token!

        expect(token).to be_present
        expect(token.length).to eq(64) # SecureRandom.hex(32)
        expect(agent_run.reload.proxy_token).to eq(token)
      end

      it "returns the same token on subsequent calls" do
        agent_run = create(:agent_run)
        agent_run.update_column(:proxy_token, nil)
        agent_run.reload

        first_token = agent_run.ensure_proxy_token!
        second_token = agent_run.ensure_proxy_token!

        expect(first_token).to eq(second_token)
      end

      it "uses atomic update to avoid overwriting concurrently-set tokens" do
        agent_run = create(:agent_run)
        agent_run.update_column(:proxy_token, nil)
        agent_run.reload

        # Simulate another process setting the token between the nil check and update
        concurrent_token = SecureRandom.hex(32)
        described_class.where(id: agent_run.id).update_all(proxy_token: concurrent_token)

        token = agent_run.ensure_proxy_token!

        # Should get the concurrently-set token since atomic update found 0 rows
        expect(token).to eq(concurrent_token)
        expect(agent_run.proxy_token).to eq(concurrent_token)
      end
    end

    describe "container integration methods" do
      let(:worktree_path) { Dir.mktmpdir("worktree") }
      let(:mock_container) do
        instance_double(
          Docker::Container,
          id: "abc123container",
          start: true,
          stop: true,
          delete: true,
          refresh!: true,
          info: { "State" => { "Running" => true, "ExitCode" => 0 } },
          exec: nil
        )
      end

      let(:mock_volume) { instance_double(Docker::Volume, remove: true) }

      before do
        allow(Docker::Container).to receive(:create).and_return(mock_container)
        allow(Docker::Container).to receive(:get).and_raise(Docker::Error::NotFoundError)
        allow(Docker::Volume).to receive_messages(create: mock_volume, get: mock_volume)
        allow(NetworkPolicy).to receive_messages(ensure_network!: instance_double(Docker::Network), apply_firewall_rules: nil)
      end

      after do
        FileUtils.rm_rf(worktree_path) if worktree_path && Dir.exist?(worktree_path)
      end

      describe "#provision_container" do
        it "provisions a container and persists container_id" do
          agent_run = create(:agent_run, worktree_path: worktree_path)

          result = agent_run.provision_container

          expect(result).to be_success
          expect(result[:container_id]).to eq("abc123container")
          expect(agent_run.reload.container_id).to eq("abc123container")
        end

        it "persists the host returned by a claimed pool entry" do
          agent_run = create(:agent_run, worktree_path: nil)
          pooled_service = instance_double(Containers::Provision)
          pooled_result = Containers::Provision::Result.success(
            container_id: "warm-container",
            container_host: "remote",
            service: pooled_service,
            pool_entry_id: 123
          )

          allow(Containers::PoolManager).to receive(:new)
            .with(project: agent_run.project)
            .and_return(instance_double(Containers::PoolManager, acquire: pooled_result))

          agent_run.provision_container

          expect(agent_run.reload.container_id).to eq("warm-container")
          expect(agent_run.container_host).to eq("remote")
        end

        it "persists the host returned by fresh provisioning" do
          agent_run = create(:agent_run, worktree_path: worktree_path)
          provision_service = instance_double(Containers::Provision)
          result = Containers::Provision::Result.success(container_id: "fresh-container", container_host: "remote")

          allow(Containers::PoolManager).to receive(:new)
            .with(project: agent_run.project)
            .and_return(instance_double(Containers::PoolManager, acquire: nil))
          allow(Containers::Provision).to receive(:new).and_return(provision_service)
          allow(provision_service).to receive(:provision).and_return(result)
          allow(PoolReplenishmentJob).to receive(:perform_later)

          agent_run.provision_container

          expect(agent_run.reload.container_id).to eq("fresh-container")
          expect(agent_run.container_host).to eq("remote")
          expect(PoolReplenishmentJob).to have_received(:perform_later).with(agent_run.project_id)
        end

        it "provisions container when worktree_path is blank" do
          agent_run = create(:agent_run, worktree_path: nil)

          result = agent_run.provision_container

          expect(result).to be_success
        end

        it "accepts optional container options" do
          agent_run = create(:agent_run, worktree_path: worktree_path)

          expect(Containers::Provision).to receive(:new).with(
            agent_run: agent_run,
            worktree_path: worktree_path,
            backend: Containers.backend_for(agent_run.container_host),
            memory_bytes: 1024 * 1024 * 1024
          ).and_call_original

          agent_run.provision_container(memory_bytes: 1024 * 1024 * 1024)
        end

        it "reuses a live recorded container on Temporal retry instead of provisioning a duplicate" do
          agent_run = create(:agent_run, worktree_path: worktree_path, container_id: "existing-container")
          existing = instance_double(
            Docker::Container,
            id: "existing-container",
            refresh!: true,
            info: { "State" => { "Running" => true } }
          )
          allow(Docker::Container).to receive(:get).with("existing-container").and_return(existing)

          # A second container must never be created on retry.
          expect(Docker::Container).not_to receive(:create)

          result = agent_run.provision_container

          expect(result).to be_success
          expect(result[:container_id]).to eq("existing-container")
          # container_id is unchanged — no new container recorded.
          expect(agent_run.reload.container_id).to eq("existing-container")
        end

        it "reconciles a dead recorded container on Temporal retry and provisions a fresh one" do
          agent_run = create(:agent_run, worktree_path: worktree_path, container_id: "dead-container")
          dead = instance_double(
            Docker::Container,
            id: "dead-container",
            refresh!: true,
            stop: true,
            delete: true,
            info: { "State" => { "Running" => false } }
          )
          allow(Docker::Container).to receive(:get).with("dead-container").and_return(dead)

          result = agent_run.provision_container

          expect(result).to be_success
          # The dead container was cleaned up...
          expect(dead).to have_received(:delete)
          # ...and a fresh container took its place (no orphan left behind).
          expect(agent_run.reload.container_id).to eq("abc123container")
        end

        it "reconciles a missing recorded container on Temporal retry and provisions a fresh one" do
          agent_run = create(:agent_run, worktree_path: worktree_path, container_id: "gone-container")
          allow(Docker::Container).to receive(:get).with("gone-container").and_raise(Docker::Error::NotFoundError)

          result = agent_run.provision_container

          expect(result).to be_success
          expect(agent_run.reload.container_id).to eq("abc123container")
        end
      end

      describe "#recover_in_flight_container!" do
        it "records an in-flight container that provisioning created but never persisted" do
          agent_run = create(:agent_run, worktree_path: worktree_path, container_id: nil)
          service = instance_double(Containers::Provision)
          backend = instance_double(Containers::Backends::LocalDocker)
          allow(service).to receive_messages(
            container: mock_container,
            backend: backend
          )
          allow(backend).to receive(:container_host_for).with(mock_container).and_return("local")
          agent_run.instance_variable_set(:@container_service, service)

          result = agent_run.recover_in_flight_container!

          expect(result).to eq("abc123container")
          expect(agent_run.reload.container_id).to eq("abc123container")
          expect(agent_run.container_host).to eq("local")
        end

        it "is a no-op when a container_id is already recorded" do
          agent_run = create(:agent_run, worktree_path: worktree_path, container_id: "existing-container")
          service = instance_double(Containers::Provision)
          allow(service).to receive(:container).and_return(mock_container)
          agent_run.instance_variable_set(:@container_service, service)

          expect(agent_run.recover_in_flight_container!).to be_nil
          expect(agent_run.reload.container_id).to eq("existing-container")
        end

        it "is a no-op when no in-flight container exists" do
          agent_run = create(:agent_run, worktree_path: worktree_path, container_id: nil)

          expect(agent_run.recover_in_flight_container!).to be_nil
          expect(agent_run.reload.container_id).to be_nil
        end
      end

      describe "#execute_in_container" do
        it "executes command in the provisioned container" do
          agent_run = create(:agent_run, worktree_path: worktree_path)
          agent_run.provision_container

          allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
            block.call(:stdout, "output\n") if block
          end

          result = agent_run.execute_in_container("echo hello")

          expect(result).to be_success
          expect(result[:stdout]).to eq("output\n")
        end

        it "reconnects from persisted container_id when @container_service is nil" do
          agent_run = create(:agent_run, worktree_path: worktree_path, container_id: "abc123container")
          allow(Docker::Container).to receive(:get).with("abc123container").and_return(mock_container)
          allow(mock_container).to receive(:exec) do |_cmd, **_opts, &block|
            block.call(:stdout, "reconnected\n") if block
          end

          result = agent_run.execute_in_container("echo hello")

          expect(result).to be_success
          expect(result[:stdout]).to eq("reconnected\n")
        end

        it "raises ProvisionError when no container_id is persisted" do
          agent_run = create(:agent_run, worktree_path: worktree_path)

          expect { agent_run.execute_in_container("echo hello") }
            .to raise_error(Containers::Provision::ProvisionError, /not provisioned/)
        end
      end

      describe "#cleanup_container" do
        it "cleans up the provisioned container and clears container_id" do
          agent_run = create(:agent_run, worktree_path: worktree_path)
          agent_run.provision_container

          expect(mock_container).to receive(:delete)

          agent_run.cleanup_container

          expect(agent_run.reload.container_id).to be_nil
        end

        it "reconnects from persisted container_id when @container_service is nil" do
          agent_run = create(:agent_run, worktree_path: worktree_path, container_id: "abc123container")
          allow(Docker::Container).to receive(:get).with("abc123container").and_return(mock_container)
          expect(mock_container).to receive(:delete)

          agent_run.cleanup_container

          expect(agent_run.reload.container_id).to be_nil
        end

        it "does nothing when no container_id is persisted" do
          agent_run = create(:agent_run, worktree_path: worktree_path)

          expect { agent_run.cleanup_container }.not_to raise_error
        end

        it "cleans up workspace volume when container is already gone" do
          agent_run = create(:agent_run, worktree_path: nil, container_id: "gone123")
          allow(Docker::Container).to receive(:get).with("gone123")
            .and_raise(Docker::Error::NotFoundError)

          orphan_volume = instance_double(Docker::Volume, remove: true)
          allow(Docker::Volume).to receive(:get)
            .with("paid-workspace-#{agent_run.id}")
            .and_return(orphan_volume)

          agent_run.cleanup_container(force: true)

          expect(agent_run.reload.container_id).to be_nil
          expect(orphan_volume).to have_received(:remove)
        end

        it "handles missing volume gracefully when container is already gone" do
          agent_run = create(:agent_run, worktree_path: nil, container_id: "gone456")
          allow(Docker::Container).to receive(:get).with("gone456")
            .and_raise(Docker::Error::NotFoundError)
          allow(Docker::Volume).to receive(:get)
            .with("paid-workspace-#{agent_run.id}")
            .and_raise(Docker::Error::NotFoundError)

          expect { agent_run.cleanup_container(force: true) }.not_to raise_error
          expect(agent_run.reload.container_id).to be_nil
        end

        it "skips volume cleanup for worktree-based runs when container is gone" do
          agent_run = create(:agent_run, worktree_path: worktree_path, container_id: "gone789")
          allow(Docker::Container).to receive(:get).with("gone789")
            .and_raise(Docker::Error::NotFoundError)

          expect(Docker::Volume).not_to receive(:get)

          agent_run.cleanup_container(force: true)
          expect(agent_run.reload.container_id).to be_nil
        end
      end

      describe "#with_container" do
        it "provisions, yields, and cleans up" do
          agent_run = create(:agent_run, worktree_path: worktree_path)
          yielded = false

          agent_run.with_container do |ar|
            expect(ar).to eq(agent_run)
            yielded = true
          end

          expect(yielded).to be true
        end

        it "cleans up even when block raises" do
          agent_run = create(:agent_run, worktree_path: worktree_path)
          expect(mock_container).to receive(:delete)

          expect {
            agent_run.with_container { raise "test error" }
          }.to raise_error("test error")
        end

        it "provisions container when worktree_path is blank" do
          agent_run = create(:agent_run, worktree_path: nil)

          agent_run.with_container { |run| expect(run).to eq(agent_run) }
        end
      end
    end
  end

  describe ".has_run_capacity?" do
    it "returns false without a user (fail closed)" do
      expect(described_class.has_run_capacity?).to be false
    end

    context "with user context" do
      let(:user) { create(:user) }
      let(:project) { create(:project, created_by: user, account: user.account) }

      it "returns false when user's active count reaches their max" do
        user.settings.update!(max_concurrent_runs: 1)
        create(:agent_run, :running, project: project)

        expect(described_class.has_run_capacity?(user: user)).to be false
      end

      it "caps user capacity with the tenant guardrail" do
        user.settings.update!(max_concurrent_runs: 5)
        create(:tenant_setting, account: user.account, guardrails: { "max_concurrent_runs" => 1 })
        create(:agent_run, :running, project: project)

        expect(described_class.has_run_capacity?(user: user)).to be false
      end

      it "returns true when user's active count is below their max" do
        user.settings.update!(max_concurrent_runs: 3)
        create(:agent_run, :running, project: project)

        expect(described_class.has_run_capacity?(user: user)).to be true
      end

      it "does not count unclaimed queued runs as active" do
        user.settings.update!(max_concurrent_runs: 1)
        create(:agent_run, :queued, project: project)

        expect(described_class.has_run_capacity?(user: user)).to be true
      end

      it "counts claimed queued runs against capacity" do
        user.settings.update!(max_concurrent_runs: 1)
        create(:agent_run, :queued, project: project, temporal_workflow_id: "claimed")

        expect(described_class.has_run_capacity?(user: user)).to be false
      end

      it "only counts runs from the user's projects" do
        user.settings.update!(max_concurrent_runs: 1)
        create(:agent_run, :running) # different user's project

        expect(described_class.has_run_capacity?(user: user)).to be true
      end

      it "is not affected by other users' active runs" do
        user.settings.update!(max_concurrent_runs: 5)
        # Runs from other users don't count against this user
        create(:agent_run, :running)
        create(:agent_run, :running)

        expect(described_class.has_run_capacity?(user: user)).to be true
      end

      it "counts orphaned-project runs against the account owner" do
        user.settings.update!(max_concurrent_runs: 1)
        orphaned_project = create(:project, created_by: nil, account: user.account)
        create(:agent_run, :running, project: orphaned_project)

        expect(described_class.has_run_capacity?(user: user)).to be false
      end

      it "does not count orphaned-project runs against non-owner members" do
        member = create(:user)
        create(:account_membership, account: user.account, user: member, role: :member)
        member.settings.update!(max_concurrent_runs: 1)
        orphaned_project = create(:project, created_by: nil, account: user.account)
        create(:agent_run, :running, project: orphaned_project)

        expect(described_class.has_run_capacity?(user: member)).to be true
      end
    end
  end

  describe ".active_count_for_project" do
    it "counts running and claimed runs for the given project" do
      project = create(:project)
      other_project = create(:project)

      create(:agent_run, :running, project: project)
      create(:agent_run, :queued, project: project, temporal_workflow_id: "claimed")
      create(:agent_run, :completed, project: project)
      create(:agent_run, :running, project: other_project)

      expect(described_class.active_count_for_project(project)).to eq(2)
    end

    it "returns zero when no active runs exist" do
      project = create(:project)
      create(:agent_run, :completed, project: project)

      expect(described_class.active_count_for_project(project)).to eq(0)
    end
  end

  describe ".active_count_for_host" do
    it "counts legacy blank container_host rows for renamed local hosts" do
      local_backend = instance_double(
        Containers::Backends::LocalDocker,
        remote?: false,
        all_host_identifiers: [ "qnap" ]
      )

      allow(Containers).to receive(:backend_for).with("qnap").and_return(local_backend)

      create(:agent_run, :running, container_host: nil)
      create(:agent_run, :running, container_host: "")
      create(:agent_run, :running, container_host: "qnap")
      create(:agent_run, :running, container_host: "remote")

      expect(described_class.active_count_for_host("qnap")).to eq(3)
    end
  end

  describe ".active_create_pr_count_for_account" do
    it "counts running and claimed create_pr runs for the account" do
      account = create(:account)
      user = create(:user, account: account)
      project = create(:project, account: account, created_by: user)
      other_account = create(:account)
      other_user = create(:user, account: other_account)
      other_project = create(:project, account: other_account, created_by: other_user)

      create(:agent_run, :running, project: project, goal: "create_pr")
      create(:agent_run, :queued, project: project, goal: "create_pr", temporal_workflow_id: "claimed")
      create(:agent_run, :running, project: project, goal: "create_issue")
      create(:agent_run, :completed, project: project, goal: "create_pr")
      create(:agent_run, :running, project: other_project, goal: "create_pr")

      expect(described_class.active_create_pr_count_for_account(account)).to eq(2)
    end

    it "returns zero when no active create_pr runs exist" do
      account = create(:account)
      user = create(:user, account: account)
      project = create(:project, account: account, created_by: user)
      create(:agent_run, :completed, project: project, goal: "create_pr")

      expect(described_class.active_create_pr_count_for_account(account)).to eq(0)
    end
  end

  describe ".next_queued_run" do
    it "returns the oldest queued run when all have the same priority" do
      older = create(:agent_run, :queued, created_at: 2.minutes.ago)
      create(:agent_run, :queued, created_at: 1.minute.ago)

      expect(described_class.next_queued_run).to eq(older)
    end

    it "returns nil when no queued runs exist" do
      create(:agent_run, :running)

      expect(described_class.next_queued_run).to be_nil
    end

    it "prioritizes manual runs over automatic runs" do
      create(:agent_run, :queued, trigger_type: "automatic", created_at: 2.minutes.ago)
      manual = create(:agent_run, :queued, trigger_type: "manual", created_at: 1.minute.ago)

      expect(described_class.next_queued_run).to eq(manual)
    end

    it "prioritizes auto-continue (PR) runs over auto-picked runs" do
      create(:agent_run, :queued, trigger_type: "automatic", created_at: 2.minutes.ago)
      auto_continue = create(:agent_run, :queued, trigger_type: "automatic",
        source_pull_request_number: 42, created_at: 1.minute.ago)

      expect(described_class.next_queued_run).to eq(auto_continue)
    end

    it "prioritizes PR-continuation work within the same priority tier" do
      project = create(:project)
      _fresh = create(:agent_run, :queued, trigger_type: "manual", project: project, created_at: 2.minutes.ago)
      pr_followup = create(:agent_run, :queued, trigger_type: "manual", project: project,
        source_pull_request_number: 7, created_at: 1.minute.ago)

      expect(described_class.next_queued_run).to eq(pr_followup)
    end

    it "prioritizes create_issue over create_pr within the same priority tier" do
      create(:agent_run, :queued, trigger_type: "manual", goal: "create_pr", created_at: 2.minutes.ago)
      issue_run = create(:agent_run, :queued, trigger_type: "manual", goal: "create_issue", created_at: 1.minute.ago)

      expect(described_class.next_queued_run).to eq(issue_run)
    end

    it "picks review runs before create_pr runs without changing visible queue order" do
      project = create(:project)
      create_pr_run = create(:agent_run, :queued, :automatic, :existing_pr,
        project: project, goal: "create_pr", source_pull_request_number: 42, created_at: 2.minutes.ago)
      review_run = create(:agent_run, :queued, :automatic, :review_goal,
        project: project, source_pull_request_number: 43, created_at: 1.minute.ago)

      queue_preview_ids = described_class.queued_with_priority.order(described_class::QUEUE_ORDER).pluck(:id)
      index_display_ids = described_class.queue_order_display.pluck(:id)

      expect(described_class.next_queued_run).to eq(review_run)
      expect(queue_preview_ids).to eq([ create_pr_run.id, review_run.id ])
      expect(index_display_ids).to eq([ create_pr_run.id, review_run.id ])
      expect(review_run.queue_priority_label).to eq(create_pr_run.queue_priority_label)
    end

    it "uses FIFO within the same priority tier and goal type" do
      create(:agent_run, :queued, trigger_type: "manual", created_at: 1.minute.ago)
      older_manual = create(:agent_run, :queued, trigger_type: "manual", created_at: 2.minutes.ago)

      expect(described_class.next_queued_run).to eq(older_manual)
    end

    it "prioritizes manual runs above P1-labeled issues within the same project" do
      project = create(:project)
      p1_issue = create(:issue, project: project, labels: [ "P1" ])
      manual_run = create(:agent_run, :queued, trigger_type: "manual", project: project, created_at: 2.minutes.ago)
      _p1_run = create(:agent_run, :queued, trigger_type: "automatic", project: project,
        issue: p1_issue, created_at: 1.minute.ago)

      expect(described_class.next_queued_run).to eq(manual_run)
    end

    it "prioritizes auto-continue (PR) runs above P2-labeled fresh issues" do
      project = create(:project)
      p2_issue = create(:issue, project: project, labels: [ "P2" ])
      auto_continue = create(:agent_run, :queued, trigger_type: "automatic", project: project,
        source_pull_request_number: 42, created_at: 2.minutes.ago)
      _p2_run = create(:agent_run, :queued, trigger_type: "automatic", project: project,
        issue: p2_issue, created_at: 1.minute.ago)

      expect(described_class.next_queued_run).to eq(auto_continue)
    end

    it "prioritizes P3-labeled issues above plain auto-pick runs" do
      project = create(:project)
      p3_issue = create(:issue, project: project, labels: [ "P3" ])
      plain_issue = create(:issue, project: project, labels: [])
      _auto_pick = create(:agent_run, :queued, trigger_type: "automatic", project: project,
        issue: plain_issue, created_at: 2.minutes.ago)
      p3_run = create(:agent_run, :queued, trigger_type: "automatic", project: project,
        issue: p3_issue, created_at: 1.minute.ago)

      expect(described_class.next_queued_run).to eq(p3_run)
    end

    it "respects custom priority label names from project settings" do
      project = create(:project, priority_labels: { "P1" => "critical", "P2" => "important" })
      critical_issue = create(:issue, project: project, labels: [ "critical" ])
      critical_run = create(:agent_run, :queued, trigger_type: "automatic", project: project,
        issue: critical_issue)

      expect(critical_run.queue_priority_tier).to eq(:issue_p1)
    end

    it "resolves labels from PR issue via source_pull_request_number" do
      project = create(:project)
      _pr_issue = create(:issue, project: project, labels: [ "P1" ],
        is_pull_request: true, github_number: 99)
      pr_run = create(:agent_run, :queued, trigger_type: "automatic", project: project,
        issue: nil, custom_prompt: "Fix PR", source_pull_request_number: 99)

      expect(pr_run.queue_priority_tier).to eq(:pr_p1)
    end

    context "with all 9 priority tiers" do
      let(:project) { create(:project) }

      def issue_run(project, minutes_ago, label: nil)
        issue = create(:issue, project: project, labels: Array(label))
        create(:agent_run, :queued, trigger_type: "automatic", project: project,
          issue: issue, created_at: minutes_ago.minutes.ago)
      end

      def pr_run(project, minutes_ago, github_number:, label: nil)
        create(:issue, project: project, labels: Array(label), is_pull_request: true, github_number: github_number)
        create(:agent_run, :queued, trigger_type: "automatic", project: project, issue: nil,
          custom_prompt: "Fix PR", source_pull_request_number: github_number, created_at: minutes_ago.minutes.ago)
      end

      it "produces correct ordering across all tiers" do
        auto_pick = issue_run(project, 9)
        issue_p3_run = issue_run(project, 8, label: "P3")
        issue_p2_run = issue_run(project, 7, label: "P2")
        issue_p1_run = issue_run(project, 6, label: "P1")
        auto_continue = pr_run(project, 5, github_number: 100)
        pr_p3_run = pr_run(project, 4, github_number: 103, label: "P3")
        pr_p2_run = pr_run(project, 3, github_number: 102, label: "P2")
        manual_run = create(:agent_run, :queued, trigger_type: "manual", project: project,
          issue: create(:issue, project: project, labels: []), created_at: 2.minutes.ago)
        pr_p1_run = pr_run(project, 1, github_number: 101, label: "P1")

        ordered_ids = described_class.queued_with_priority.order(described_class::QUEUE_ORDER).pluck(:id)
        expect(ordered_ids).to eq(
          [ manual_run, pr_p1_run, pr_p2_run, pr_p3_run, auto_continue,
            issue_p1_run, issue_p2_run, issue_p3_run, auto_pick ].map(&:id)
        )
      end
    end
  end

  describe ".retry_trigger_type_for" do
    let(:project) { create(:project) }

    it "inherits manual priority from the latest unsuccessful PR run for the same goal" do
      create(:agent_run, :timeout, :manual, project: project,
        source_pull_request_number: 42,
        goal: "create_pr",
        completed_at: 5.minutes.ago)

      trigger_type = described_class.retry_trigger_type_for(
        project: project,
        source_pull_request_number: 42,
        goal: "create_pr"
      )

      expect(trigger_type).to eq("manual")
    end

    it "keeps automatic priority when a newer unsuccessful PR run was automatic" do
      create(:agent_run, :timeout, :manual, project: project,
        source_pull_request_number: 42,
        goal: "create_pr",
        completed_at: 10.minutes.ago)
      create(:agent_run, :failed, :automatic, project: project,
        source_pull_request_number: 42,
        goal: "create_pr",
        completed_at: 5.minutes.ago)

      trigger_type = described_class.retry_trigger_type_for(
        project: project,
        source_pull_request_number: 42,
        goal: "create_pr"
      )

      expect(trigger_type).to eq("automatic")
    end

    it "does not inherit priority from a successful PR run" do
      create(:agent_run, :completed, :manual, project: project,
        source_pull_request_number: 42,
        goal: "create_pr",
        completed_at: 5.minutes.ago)

      trigger_type = described_class.retry_trigger_type_for(
        project: project,
        source_pull_request_number: 42,
        goal: "create_pr"
      )

      expect(trigger_type).to eq("automatic")
    end

    it "treats a completed run as a reset boundary before an older manual failure" do
      create(:agent_run, :timeout, :manual, project: project,
        source_pull_request_number: 42,
        goal: "create_pr",
        completed_at: 10.minutes.ago)
      create(:agent_run, :completed, :automatic, project: project,
        source_pull_request_number: 42,
        goal: "create_pr",
        completed_at: 5.minutes.ago)

      trigger_type = described_class.retry_trigger_type_for(
        project: project,
        source_pull_request_number: 42,
        goal: "create_pr"
      )

      expect(trigger_type).to eq("automatic")
    end

    it "inherits manual priority again from a manual failure after a completed reset" do
      create(:agent_run, :timeout, :manual, project: project,
        source_pull_request_number: 42,
        goal: "create_pr",
        completed_at: 15.minutes.ago)
      create(:agent_run, :completed, :automatic, project: project,
        source_pull_request_number: 42,
        goal: "create_pr",
        completed_at: 10.minutes.ago)
      create(:agent_run, :timeout, :manual, project: project,
        source_pull_request_number: 42,
        goal: "create_pr",
        completed_at: 5.minutes.ago)

      trigger_type = described_class.retry_trigger_type_for(
        project: project,
        source_pull_request_number: 42,
        goal: "create_pr"
      )

      expect(trigger_type).to eq("manual")
    end
  end

  describe ".peek_next_queued_run" do
    def claim_peeked_run
      run = described_class.claim_next_queued_run(target_id: described_class.peek_next_queued_run.id)
      run&.update!(status: "running", started_at: Time.current)
      run
    end

    it "returns the highest-priority queued run without changing status" do
      create(:agent_run, :queued, trigger_type: "automatic", created_at: 2.minutes.ago)
      manual = create(:agent_run, :queued, trigger_type: "manual", created_at: 1.minute.ago)

      peeked = described_class.peek_next_queued_run

      expect(peeked).to eq(manual)
      expect(manual.reload.status).to eq("queued")
    end

    it "returns nil when no queued runs exist" do
      create(:agent_run, :running)

      expect(described_class.peek_next_queued_run).to be_nil
    end

    it "skips excluded IDs" do
      manual = create(:agent_run, :queued, trigger_type: "manual", created_at: 2.minutes.ago)
      auto = create(:agent_run, :queued, trigger_type: "automatic", created_at: 1.minute.ago)

      peeked = described_class.peek_next_queued_run(exclude_ids: [ manual.id ])

      expect(peeked).to eq(auto)
    end

    it "round robins same-tier runs across projects (cross-project fair-share)" do
      account = create(:account)
      user = create(:user, account: account)
      first_project = create(:project, account: account, created_by: user)
      second_project = create(:project, account: account, created_by: user)
      first_run = create(:agent_run, :queued, :manual, project: first_project, created_at: 4.minutes.ago)
      second_run = create(:agent_run, :queued, :manual, project: first_project, created_at: 3.minutes.ago)
      third_run = create(:agent_run, :queued, :manual, project: second_project, created_at: 2.minutes.ago)
      fourth_run = create(:agent_run, :queued, :manual, project: second_project, created_at: 1.minute.ago)

      peeked_ids = 4.times.map { claim_peeked_run.id }

      expect(peeked_ids).to eq([ first_run.id, third_run.id, second_run.id, fourth_run.id ])
    end

    it "dequeues user with fewer active runs first (cross-user fair-share)" do
      first_account = create(:account)
      first_user = create(:user, account: first_account)
      first_user.settings.update!(max_concurrent_runs: 2)
      active_project = create(:project, account: first_account, created_by: first_user)
      create(:agent_run, :running, project: active_project)
      create(:agent_run, :queued, :manual, project: active_project, created_at: 2.minutes.ago)

      second_account = create(:account)
      second_user = create(:user, account: second_account)
      second_user.settings.update!(max_concurrent_runs: 2)
      idle_project = create(:project, account: second_account, created_by: second_user)
      idle_run = create(:agent_run, :queued, :manual, project: idle_project, created_at: 1.minute.ago)

      expect(described_class.peek_next_queued_run).to eq(idle_run)
    end

    it "lets a single active project keep FIFO order while using capacity" do
      project = create(:project)
      first_run = create(:agent_run, :queued, :manual, project: project, created_at: 3.minutes.ago)
      second_run = create(:agent_run, :queued, :manual, project: project, created_at: 2.minutes.ago)
      third_run = create(:agent_run, :queued, :manual, project: project, created_at: 1.minute.ago)

      peeked_ids = 3.times.map { claim_peeked_run.id }

      expect(peeked_ids).to eq([ first_run.id, second_run.id, third_run.id ])
    end

    it "excludes paused runs from the project stride count" do
      account = create(:account)
      user = create(:user, account: account)
      first_project = create(:project, account: account, created_by: user)
      second_project = create(:project, account: account, created_by: user)
      first_run = create(:agent_run, :queued, :manual, project: first_project, created_at: 2.minutes.ago)
      second_run = create(:agent_run, :queued, :manual, project: second_project, created_at: 1.minute.ago)
      create(:agent_run, :paused, project: first_project)

      expect(described_class.peek_next_queued_run).to eq(first_run)
      described_class.claim_next_queued_run(target_id: first_run.id)
      expect(described_class.peek_next_queued_run).to eq(second_run)
    end

    it "interleaves two users with same-tier runs (user with fewer active runs first)" do
      first_account = create(:account)
      first_user = create(:user, account: first_account)
      first_user.settings.update!(max_concurrent_runs: 5)
      first_project = create(:project, account: first_account, created_by: first_user)

      second_account = create(:account)
      second_user = create(:user, account: second_account)
      second_user.settings.update!(max_concurrent_runs: 5)
      second_project = create(:project, account: second_account, created_by: second_user)

      run_a1 = create(:agent_run, :queued, :manual, project: first_project, created_at: 4.minutes.ago)
      run_a2 = create(:agent_run, :queued, :manual, project: first_project, created_at: 3.minutes.ago)
      run_b1 = create(:agent_run, :queued, :manual, project: second_project, created_at: 2.minutes.ago)
      run_b2 = create(:agent_run, :queued, :manual, project: second_project, created_at: 1.minute.ago)

      peeked_ids = 4.times.map { claim_peeked_run.id }

      expect(peeked_ids).to eq([ run_a1.id, run_b1.id, run_a2.id, run_b2.id ])
    end

    it "gives single user on system full capacity without unfair throttling" do
      account = create(:account)
      user = create(:user, account: account)
      user.settings.update!(max_concurrent_runs: 5)
      project = create(:project, account: account, created_by: user)

      runs = 3.times.map do |i|
        create(:agent_run, :queued, :manual, project: project, created_at: (3 - i).minutes.ago)
      end

      peeked_ids = 3.times.map { claim_peeked_run.id }

      expect(peeked_ids).to eq(runs.map(&:id))
    end

    it "attributes orphaned project counts to account fallback owner" do
      account = create(:account)
      owner = create(:user, account: account)
      owner.settings.update!(max_concurrent_runs: 5)
      orphaned_project = create(:project, account: account, created_by: nil)
      owned_project = create(:project, account: account, created_by: owner)

      create(:agent_run, :running, project: orphaned_project)

      other_account = create(:account)
      other_user = create(:user, account: other_account)
      other_user.settings.update!(max_concurrent_runs: 5)
      other_project = create(:project, account: other_account, created_by: other_user)

      _owned_run = create(:agent_run, :queued, :manual, project: owned_project, created_at: 2.minutes.ago)
      other_run = create(:agent_run, :queued, :manual, project: other_project, created_at: 1.minute.ago)

      expect(described_class.peek_next_queued_run).to eq(other_run)
    end

    it "combines cross-user and per-project stride for fair interleaving at both levels" do
      first_account = create(:account)
      first_user = create(:user, account: first_account)
      first_user.settings.update!(max_concurrent_runs: 5)
      proj_a1 = create(:project, account: first_account, created_by: first_user)
      proj_a2 = create(:project, account: first_account, created_by: first_user)

      second_account = create(:account)
      second_user = create(:user, account: second_account)
      second_user.settings.update!(max_concurrent_runs: 5)
      proj_b1 = create(:project, account: second_account, created_by: second_user)

      run_a1 = create(:agent_run, :queued, :manual, project: proj_a1, created_at: 5.minutes.ago)
      run_a2 = create(:agent_run, :queued, :manual, project: proj_a2, created_at: 4.minutes.ago)
      run_a3 = create(:agent_run, :queued, :manual, project: proj_a1, created_at: 3.minutes.ago)
      run_b1 = create(:agent_run, :queued, :manual, project: proj_b1, created_at: 2.minutes.ago)

      peeked_ids = 4.times.map { claim_peeked_run.id }

      expect(peeked_ids).to eq([ run_a1.id, run_b1.id, run_a2.id, run_a3.id ])
    end

    it "lets a low-priority run from an idle project pre-empt a high-priority flood elsewhere" do
      account = create(:account)
      user = create(:user, account: account)
      user.settings.update!(max_concurrent_runs: 10)
      flooded = create(:project, account: account, created_by: user)
      idle = create(:project, account: account, created_by: user)

      # `flooded` has 2 P1 runs already in flight, plus a third P1 queued behind.
      flooded_p1_a = create(:issue, project: flooded, labels: [ "P1" ])
      flooded_p1_b = create(:issue, project: flooded, labels: [ "P1" ])
      flooded_p1_c = create(:issue, project: flooded, labels: [ "P1" ])
      create(:agent_run, :running, project: flooded, trigger_type: "automatic", issue: flooded_p1_a)
      create(:agent_run, :running, project: flooded, trigger_type: "automatic", issue: flooded_p1_b)
      create(:agent_run, :queued, trigger_type: "automatic", project: flooded,
        issue: flooded_p1_c, created_at: 5.minutes.ago)

      # `idle` only has a P2 queued — but its project is idle, so it gets a turn.
      idle_p2 = create(:issue, project: idle, labels: [ "P2" ])
      idle_p2_run = create(:agent_run, :queued, trigger_type: "automatic", project: idle,
        issue: idle_p2, created_at: 1.minute.ago)

      expect(described_class.peek_next_queued_run).to eq(idle_p2_run)
    end

    it "preserves strict priority order within a single project" do
      project = create(:project)
      p1_issue = create(:issue, project: project, labels: [ "P1" ])
      p2_issue = create(:issue, project: project, labels: [ "P2" ])
      p3_issue = create(:issue, project: project, labels: [ "P3" ])
      p3_run = create(:agent_run, :queued, trigger_type: "automatic", project: project,
        issue: p3_issue, created_at: 3.minutes.ago)
      p2_run = create(:agent_run, :queued, trigger_type: "automatic", project: project,
        issue: p2_issue, created_at: 2.minutes.ago)
      p1_run = create(:agent_run, :queued, trigger_type: "automatic", project: project,
        issue: p1_issue, created_at: 1.minute.ago)

      peeked_ids = 3.times.map { claim_peeked_run.id }

      expect(peeked_ids).to eq([ p1_run.id, p2_run.id, p3_run.id ])
    end

    it "excludes paused runs from the user active count" do
      first_account = create(:account)
      first_user = create(:user, account: first_account)
      first_user.settings.update!(max_concurrent_runs: 5)
      first_project = create(:project, account: first_account, created_by: first_user)
      create(:agent_run, :paused, project: first_project)

      second_account = create(:account)
      second_user = create(:user, account: second_account)
      second_user.settings.update!(max_concurrent_runs: 5)
      second_project = create(:project, account: second_account, created_by: second_user)

      first_run = create(:agent_run, :queued, :manual, project: first_project, created_at: 2.minutes.ago)
      create(:agent_run, :queued, :manual, project: second_project, created_at: 1.minute.ago)

      expect(described_class.peek_next_queued_run).to eq(first_run)
    end
  end

  describe ".claim_next_queued_run" do
    it "claims a specific queued run by setting temporal_workflow_id" do
      run = create(:agent_run, :queued)

      claimed = described_class.claim_next_queued_run(target_id: run.id)

      expect(claimed).to eq(run)
      expect(claimed.temporal_workflow_id).to eq("claimed")
      expect(claimed.status).to eq("queued")
      expect(run.reload.temporal_workflow_id).to eq("claimed")
      expect(run.reload.status).to eq("queued")
    end

    it "returns nil when the target run is no longer queued" do
      run = create(:agent_run, :running)

      expect(described_class.claim_next_queued_run(target_id: run.id)).to be_nil
    end

    it "returns nil when the target ID does not exist" do
      expect(described_class.claim_next_queued_run(target_id: -1)).to be_nil
    end
  end

  describe "#queue_priority_tier" do
    it "returns :manual for manual trigger type" do
      run = create(:agent_run, trigger_type: "manual")

      expect(run.queue_priority_tier).to eq(:manual)
    end

    it "returns :pr_continue for automatic runs with a source PR" do
      run = create(:agent_run, trigger_type: "automatic", source_pull_request_number: 42)

      expect(run.queue_priority_tier).to eq(:pr_continue)
    end

    it "returns :auto_pick for automatic runs without a source PR" do
      run = create(:agent_run, trigger_type: "automatic")

      expect(run.queue_priority_tier).to eq(:auto_pick)
    end

    it "returns :issue_p1 when the issue has the P1 label" do
      project = create(:project)
      issue = create(:issue, project: project, labels: [ "P1" ])
      run = create(:agent_run, trigger_type: "automatic", project: project, issue: issue)

      expect(run.queue_priority_tier).to eq(:issue_p1)
    end

    it "returns :issue_p2 when the issue has the P2 label" do
      project = create(:project)
      issue = create(:issue, project: project, labels: [ "P2" ])
      run = create(:agent_run, trigger_type: "automatic", project: project, issue: issue)

      expect(run.queue_priority_tier).to eq(:issue_p2)
    end

    it "returns :issue_p3 when the issue has the P3 label" do
      project = create(:project)
      issue = create(:issue, project: project, labels: [ "P3" ])
      run = create(:agent_run, trigger_type: "automatic", project: project, issue: issue)

      expect(run.queue_priority_tier).to eq(:issue_p3)
    end

    it "uses custom label names from project priority_labels" do
      project = create(:project, priority_labels: { "P1" => "urgent" })
      issue = create(:issue, project: project, labels: [ "urgent" ])
      run = create(:agent_run, trigger_type: "automatic", project: project, issue: issue)

      expect(run.queue_priority_tier).to eq(:issue_p1)
    end

    it "returns :pr_p1 when the source PR has the P1 label, taking precedence over PR category" do
      project = create(:project)
      create(:issue, project: project, labels: [ "P1" ], is_pull_request: true, github_number: 55)
      run = create(:agent_run, trigger_type: "automatic", project: project, source_pull_request_number: 55)

      expect(run.queue_priority_tier).to eq(:pr_p1)
    end
  end

  describe "#queue_priority_label" do
    it "returns '1 - Manual' for manual runs" do
      run = create(:agent_run, trigger_type: "manual")

      expect(run.queue_priority_label).to eq("1 - Manual")
    end

    it "returns '5 - Auto-continue' for automatic runs with a source PR" do
      run = create(:agent_run, trigger_type: "automatic", source_pull_request_number: 42)

      expect(run.queue_priority_label).to eq("5 - Auto-continue")
    end

    it "returns '9 - Auto-pick' for automatic runs without a source PR" do
      run = create(:agent_run, trigger_type: "automatic")

      expect(run.queue_priority_label).to eq("9 - Auto-pick")
    end

    it "returns '2 - PR · P1' for a PR-continuation run with the P1 label" do
      project = create(:project)
      create(:issue, project: project, labels: [ "P1" ], is_pull_request: true, github_number: 201)
      run = create(:agent_run, trigger_type: "automatic", project: project, source_pull_request_number: 201)

      expect(run.queue_priority_label).to eq("2 - PR · P1")
    end

    it "returns '3 - PR · P2' for a PR-continuation run with the P2 label" do
      project = create(:project)
      create(:issue, project: project, labels: [ "P2" ], is_pull_request: true, github_number: 202)
      run = create(:agent_run, trigger_type: "automatic", project: project, source_pull_request_number: 202)

      expect(run.queue_priority_label).to eq("3 - PR · P2")
    end

    it "returns '4 - PR · P3' for a PR-continuation run with the P3 label" do
      project = create(:project)
      create(:issue, project: project, labels: [ "P3" ], is_pull_request: true, github_number: 203)
      run = create(:agent_run, trigger_type: "automatic", project: project, source_pull_request_number: 203)

      expect(run.queue_priority_label).to eq("4 - PR · P3")
    end
  end

  describe "user-defined priority labels" do
    let(:project) { create(:project, priority_labels: { "P1" => "critical", "P2" => "high", "P3" => "low" }) }

    def queued_run_with_issue_labels(labels, **attrs)
      issue = create(:issue, project: project, labels: labels)
      create(:agent_run, :queued, project: project, issue: issue, **attrs)
    end

    it "returns :issue_p1 when issue carries the configured P1 label" do
      run = queued_run_with_issue_labels([ "critical" ], trigger_type: "automatic")

      expect(run.queue_priority_tier).to eq(:issue_p1)
    end

    it "matches configured priority labels case-insensitively" do
      run = queued_run_with_issue_labels([ "CRITICAL" ], trigger_type: "automatic")

      expect(run.queue_priority_tier).to eq(:issue_p1)
    end

    it "ranks manual above P1 within the same project" do
      p1 = queued_run_with_issue_labels([ "critical" ], trigger_type: "automatic", created_at: 2.minutes.ago)
      manual = create(:agent_run, :queued, project: project, trigger_type: "manual", created_at: 1.minute.ago)

      expect(described_class.next_queued_run).to eq(manual)
      _ = p1
    end

    it "ranks auto-continue (PR) above P2-labeled fresh issue but below manual" do
      manual = create(:agent_run, :queued, project: project, trigger_type: "manual", created_at: 3.minutes.ago)
      auto_continue = create(:agent_run, :queued, project: project, trigger_type: "automatic",
        source_pull_request_number: 99, created_at: 1.minute.ago)
      p2 = queued_run_with_issue_labels([ "high" ], trigger_type: "automatic", created_at: 2.minutes.ago)

      ordered = described_class.queued_with_priority.order(described_class::QUEUE_ORDER).to_a
      expect(ordered).to eq([ manual, auto_continue, p2 ])
    end

    it "ranks P3 above auto-pick but below auto-continue" do
      auto_pick = create(:agent_run, :queued, project: project, trigger_type: "automatic", created_at: 3.minutes.ago)
      auto_continue = create(:agent_run, :queued, project: project, trigger_type: "automatic",
        source_pull_request_number: 99, created_at: 1.minute.ago)
      p3 = queued_run_with_issue_labels([ "low" ], trigger_type: "automatic", created_at: 2.minutes.ago)

      ordered = described_class.queued_with_priority.order(described_class::QUEUE_ORDER).to_a
      expect(ordered).to eq([ auto_continue, p3, auto_pick ])
    end

    it "orders queued runs by priority labels case-insensitively" do
      auto_pick = create(:agent_run, :queued, project: project, trigger_type: "automatic", created_at: 3.minutes.ago)
      p1 = queued_run_with_issue_labels([ "CRITICAL" ], trigger_type: "automatic", created_at: 2.minutes.ago)
      p2 = queued_run_with_issue_labels([ "HIGH" ], trigger_type: "automatic", created_at: 1.minute.ago)

      ordered = described_class.queued_with_priority.order(described_class::QUEUE_ORDER).to_a
      expect(ordered).to eq([ p1, p2, auto_pick ])
    end

    it "picks the highest priority when multiple labels are present" do
      run = queued_run_with_issue_labels([ "low", "critical", "high" ], trigger_type: "automatic")

      expect(run.queue_priority_tier).to eq(:issue_p1)
    end

    it "reads priority labels from a source pull request when no issue is set" do
      pr_record = create(:issue, project: project, github_number: 555, is_pull_request: true, labels: [ "critical" ])
      run = create(:agent_run, :queued, project: project, trigger_type: "automatic",
        source_pull_request_number: 555)

      expect(run.queue_priority_tier).to eq(:pr_p1)
      _ = pr_record
    end

    it "considers labels from both issue and source PR (split-label scenario)" do
      issue = create(:issue, project: project, labels: [ "low" ])
      create(:issue, project: project, github_number: 777, is_pull_request: true, labels: [ "critical" ])
      split_run = create(:agent_run, :queued, project: project, trigger_type: "automatic",
        issue: issue, source_pull_request_number: 777)

      expect(split_run.queue_priority_tier).to eq(:pr_p1)
    end

    describe ".preload_source_pull_requests" do
      it "stashes the matching PR Issue row on each run with one query" do
        pr_a = create(:issue, project: project, github_number: 101, is_pull_request: true, labels: [ "critical" ])
        pr_b = create(:issue, project: project, github_number: 102, is_pull_request: true, labels: [ "high" ])
        run_a = create(:agent_run, :queued, project: project, trigger_type: "automatic", source_pull_request_number: 101)
        run_b = create(:agent_run, :queued, project: project, trigger_type: "automatic", source_pull_request_number: 102)
        run_none = create(:agent_run, :queued, project: project, trigger_type: "manual")

        runs = [ run_a, run_b, run_none ]
        query_count = 0
        counter = ->(_, _, _, _, payload) {
          query_count += 1 unless payload[:name] == "SCHEMA" || payload[:sql] =~ /^(BEGIN|COMMIT|ROLLBACK)/
        }
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
          described_class.preload_source_pull_requests(runs)
        end

        expect(query_count).to eq(1)
        expect(run_a.source_pull_request_record).to eq(pr_a)
        expect(run_b.source_pull_request_record).to eq(pr_b)
        expect(run_none.source_pull_request_record).to be_nil
      end

      it "does not re-query for runs that already have a memoized record" do
        pr = create(:issue, project: project, github_number: 200, is_pull_request: true, labels: [ "critical" ])
        run = create(:agent_run, :queued, project: project, trigger_type: "automatic", source_pull_request_number: 200)
        run.source_pull_request_record = pr

        expect(Issue).not_to receive(:where)
        described_class.preload_source_pull_requests([ run ])
      end
    end

    it "returns '6 - P1' for P1-labeled fresh issues" do
      project = create(:project)
      issue = create(:issue, project: project, labels: [ "P1" ])
      run = create(:agent_run, trigger_type: "automatic", project: project, issue: issue)

      expect(run.queue_priority_label).to eq("6 - P1")
    end
  end

  describe "constants" do
    it "defines valid STATUSES" do
      expect(described_class::STATUSES).to eq(%w[queued running paused completed no_output failed cancelled timeout token_budget_exceeded retried auth_expired rate_limited])
    end

    it "counts running and claimed queued runs in capacity_inflight scope" do
      running = create(:agent_run, :running)
      _claimed = create(:agent_run, status: "queued", temporal_workflow_id: "claimed")
      _unclaimed = create(:agent_run, status: "queued")

      expect(described_class.capacity_inflight).to contain_exactly(running, _claimed)
    end

    it "defines valid AGENT_TYPES" do
      expect(described_class::AGENT_TYPES).to eq(%w[claude_code cursor codex copilot aider gemini opencode kilocode pi api devin factory internal_agent])
    end

    it "defines valid GOALS" do
      expect(described_class::GOALS).to eq(%w[create_pr create_issue review enhance_issue analyze_issue])
    end

    it "defines valid TRIGGER_TYPES" do
      expect(described_class::TRIGGER_TYPES).to eq(%w[manual automatic])
    end
  end

  describe "defaults" do
    it "defaults status to queued" do
      agent_run = create(:agent_run)
      expect(agent_run.status).to eq("queued")
    end

    it "defaults iterations to 0" do
      agent_run = create(:agent_run)
      expect(agent_run.iterations).to eq(0)
    end

    it "defaults tokens_input to 0" do
      agent_run = create(:agent_run)
      expect(agent_run.tokens_input).to eq(0)
    end

    it "defaults tokens_output to 0" do
      agent_run = create(:agent_run)
      expect(agent_run.tokens_output).to eq(0)
    end

    it "defaults cost_cents to 0" do
      agent_run = create(:agent_run)
      expect(agent_run.cost_cents).to eq(0)
    end

    it "defaults trigger_type to automatic" do
      agent_run = create(:agent_run)
      expect(agent_run.trigger_type).to eq("automatic")
    end
  end

  describe "project association" do
    it "is destroyed when project is destroyed" do
      project = create(:project)
      agent_run = create(:agent_run, project: project)

      expect { project.destroy }.to change(described_class, :count).by(-1)
      expect { agent_run.reload }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "issue association" do
    it "allows agent_run to exist without issue when custom_prompt is present" do
      agent_run = create(:agent_run, issue: nil, custom_prompt: "Do something")
      expect(agent_run.issue).to be_nil
      expect(agent_run).to be_valid
    end

    it "sets issue to nil when issue is destroyed" do
      issue = create(:issue)
      agent_run = create(:agent_run, project: issue.project, issue: issue)

      issue.destroy
      agent_run.reload

      expect(agent_run.issue_id).to be_nil
    end
  end

  describe "agent_run_logs association" do
    it "destroys logs when agent_run is destroyed" do
      agent_run = create(:agent_run)
      create(:agent_run_log, agent_run: agent_run)
      create(:agent_run_log, agent_run: agent_run)

      expect { agent_run.destroy }.to change(AgentRunLog, :count).by(-2)
    end
  end

  describe "broadcast callbacks" do
    let(:project) { create(:project) }

    it "broadcasts all updates on create (status changes)" do
      allow(project).to receive(:broadcast_agent_runs_update)
      allow(project).to receive(:broadcast_agent_runs_list_update)
      allow(project).to receive(:broadcast_stats_update)
      allow(project).to receive(:broadcast_cost_snapshot_update)
      allow(project).to receive(:broadcast_agent_run_detail_update)

      agent_run = create(:agent_run, project: project)

      expect(project).to have_received(:broadcast_agent_runs_update)
      expect(project).to have_received(:broadcast_agent_runs_list_update)
      expect(project).to have_received(:broadcast_stats_update)
      expect(project).not_to have_received(:broadcast_cost_snapshot_update)
      expect(project).to have_received(:broadcast_agent_run_detail_update).with(agent_run)
    end

    it "broadcasts all updates on status change" do
      allow(project).to receive(:broadcast_agent_runs_update)
      allow(project).to receive(:broadcast_agent_runs_list_update)
      allow(project).to receive(:broadcast_stats_update)
      allow(project).to receive(:broadcast_cost_snapshot_update)
      allow(project).to receive(:broadcast_agent_run_detail_update)
      agent_run = create(:agent_run, project: project)

      expect(project).to receive(:broadcast_agent_runs_update).once
      expect(project).to receive(:broadcast_agent_runs_list_update).once
      expect(project).to receive(:broadcast_stats_update).once
      expect(project).to receive(:broadcast_cost_snapshot_update).once
      expect(project).to receive(:broadcast_agent_run_detail_update).with(agent_run).once

      agent_run.update!(status: "running", started_at: Time.current)
    end

    it "only broadcasts detail update on non-key attribute changes" do
      allow(project).to receive(:broadcast_agent_runs_update)
      allow(project).to receive(:broadcast_agent_runs_list_update)
      allow(project).to receive(:broadcast_stats_update)
      allow(project).to receive(:broadcast_cost_snapshot_update)
      allow(project).to receive(:broadcast_agent_run_detail_update)
      agent_run = create(:agent_run, project: project, status: "running", started_at: Time.current)

      expect(project).not_to receive(:broadcast_agent_runs_update)
      expect(project).not_to receive(:broadcast_agent_runs_list_update)
      expect(project).not_to receive(:broadcast_stats_update)
      expect(project).not_to receive(:broadcast_cost_snapshot_update)
      expect(project).to receive(:broadcast_agent_run_detail_update).with(agent_run).once

      agent_run.update!(tokens_input: 1000, tokens_output: 500, cost_cents: 10)
    end

    context "with issue-backed runs" do
      let(:issue) { create(:issue, project: project) }

      before do
        allow(project).to receive(:broadcast_agent_runs_update)
        allow(project).to receive(:broadcast_agent_runs_list_update)
        allow(project).to receive(:broadcast_stats_update)
        allow(project).to receive(:broadcast_cost_snapshot_update)
        allow(project).to receive(:broadcast_agent_run_detail_update)
        allow(project).to receive(:broadcast_issues_update)
      end

      it "broadcasts issues update when an issue-backed run transitions to a terminal status" do
        agent_run = create(:agent_run, project: project, issue: issue, status: "running", started_at: Time.current)

        expect(project).to receive(:broadcast_issues_update).once
        agent_run.update!(status: "failed")
      end

      it "broadcasts issues update when transitioning from nil to a blocking status (create)" do
        issue
        expect(project).to receive(:broadcast_issues_update).once
        create(:agent_run, project: project, issue: issue, status: "running", started_at: Time.current)
      end

      it "does not broadcast issues update for intermediate transitions within blocking statuses" do
        agent_run = create(:agent_run, project: project, issue: issue, status: "running", started_at: Time.current)

        expect(project).not_to receive(:broadcast_issues_update)
        agent_run.update!(status: "paused", paused_at: Time.current)
      end

      it "does not broadcast issues update for non-issue runs" do
        agent_run = create(:agent_run, :with_custom_prompt, project: project, status: "running", started_at: Time.current)

        expect(project).not_to receive(:broadcast_issues_update)
        agent_run.update!(status: "failed")
      end
    end
  end

  describe "#record_runner_attempt" do
    it "appends an attempt to runners_attempted" do
      agent_run = create(:agent_run)
      agent_run.record_runner_attempt("claude", success: true)

      agent_run.reload
      expect(agent_run.runners_attempted.size).to eq(1)
      expect(agent_run.runners_attempted.first["runner"]).to eq("claude")
      expect(agent_run.runners_attempted.first["success"]).to be true
    end

    it "records error_type for failed attempts" do
      agent_run = create(:agent_run)
      agent_run.record_runner_attempt("claude", success: false, error_type: "rate_limited")

      attempt = agent_run.reload.runners_attempted.last
      expect(attempt["error_type"]).to eq("rate_limited")
    end

    it "records error_message for failed attempts" do
      agent_run = create(:agent_run)
      agent_run.record_runner_attempt("claude", success: false, error_type: "error", error_message: "Configuration is invalid")

      attempt = agent_run.reload.runners_attempted.last
      expect(attempt["error_message"]).to eq("Configuration is invalid")
    end

    it "redacts and truncates error_message for failed attempts" do
      agent_run = create(:agent_run)
      secret = "sk-test-super-secret-value"
      long_message = "Error: #{secret} " + ("x" * 600)

      agent_run.record_runner_attempt("claude", success: false, error_type: "error", error_message: long_message)

      attempt = agent_run.reload.runners_attempted.last
      expect(attempt["error_message"]).not_to include(secret)
      expect(attempt["error_message"].length).to be <= AgentRun::MAX_PROVIDER_ATTEMPT_ERROR_MESSAGE_LENGTH
    end

    it "sanitizes nested diagnostic string entries" do
      agent_run = create(:agent_run)
      secret = "sk-test-super-secret-value"

      agent_run.record_runner_attempt(
        "claude",
        success: false,
        error_type: "timeout",
        diagnostics: {
          "argv" => [ secret, { "message" => "Bearer #{secret}" } ],
          "messages" => [ "token #{secret}" ]
        }
      )

      attempt = agent_run.reload.runners_attempted.last
      diagnostics = attempt["diagnostics"]

      expect(diagnostics["argv"].first).not_to include(secret)
      expect(diagnostics["argv"].second["message"]).not_to include(secret)
      expect(diagnostics["messages"].first).not_to include(secret)
    end

    it "accumulates multiple attempts" do
      agent_run = create(:agent_run)
      agent_run.record_runner_attempt("claude", success: false, error_type: "rate_limited")
      agent_run.record_runner_attempt("cursor", success: true)

      expect(agent_run.reload.runners_attempted.size).to eq(2)
    end
  end

  describe "#log_provider_switch!" do
    it "creates a system log entry" do
      agent_run = create(:agent_run)
      agent_run.log_provider_switch!("claude", "cursor", "rate_limited")

      log = agent_run.agent_run_logs.last
      expect(log.log_type).to eq("system")
      expect(log.content).to include("claude")
      expect(log.content).to include("cursor")
    end

    it "increments the runner_switches counter" do
      agent_run = create(:agent_run)
      expect { agent_run.log_provider_switch!("claude", "cursor", "rate_limited") }
        .to change { agent_run.reload.runner_switches }.by(1)
    end
  end

  describe ".distinct_effective_provider_options caching" do
    around do |example|
      original_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new
      example.run
    ensure
      Rails.cache = original_cache
    end

    it "caches results by account cache key" do
      project = create(:project)
      create(:agent_run, :completed, project: project, agent_type: "claude_code")

      account_key = described_class.provider_options_cache_key_for(account_id: project.account_id)
      scope = described_class.where(project_id: project.id)

      first_call = scope.distinct_effective_provider_options(account_id: project.account_id, cache_key: account_key)
      expect(first_call).to include({ label: Runner.display_name_for("claude"), value: "claude" })

      second_call = scope.distinct_effective_provider_options(account_id: project.account_id, cache_key: account_key)
      expect(second_call).to eq(first_call)
    end

    it "returns fresh results without cache_key" do
      project = create(:project)
      create(:agent_run, :completed, project: project, agent_type: "claude_code")

      scope = described_class.where(project_id: project.id)

      first = scope.distinct_effective_provider_options(account_id: project.account_id)
      expect(first).to include({ label: Runner.display_name_for("claude"), value: "claude" })

      create(:agent_run, :completed, project: project, agent_type: "cursor")

      second = scope.distinct_effective_provider_options(account_id: project.account_id)
      expect(second).to include({ label: Runner.display_name_for("cursor"), value: "cursor" })
    end

    it "uses separate cache keys for account and project scope" do
      project = create(:project)
      create(:agent_run, :completed, project: project, agent_type: "claude_code")

      account_key = described_class.provider_options_cache_key_for(account_id: project.account_id)
      project_key = described_class.provider_options_cache_key_for(account_id: project.account_id, project_id: project.id)

      described_class.where(project_id: project.id).distinct_effective_provider_options(account_id: project.account_id, cache_key: account_key)
      described_class.where(project_id: project.id).distinct_effective_provider_options(account_id: project.account_id, cache_key: project_key)

      expect(Rails.cache.read(account_key)).not_to be_nil
      expect(Rails.cache.read(project_key)).not_to be_nil
    end

    it "keeps discarded runner names available for routed filter options" do
      project = create(:project)
      runner = create(:runner, user: project.effective_owner, runner_key: "opencode", name: "Kimi K2.5")
      create(:agent_run, :completed, project: project, final_runner: runner.routing_key)
      runner.discard!

      options = described_class.where(project_id: project.id).distinct_effective_provider_options(account_id: project.account_id)

      expect(options).to include({ label: "Kimi K2.5", value: runner.routing_key })
    end

    it "bulk-loads routed runner filter options without N+1 queries" do
      project = create(:project)
      providers = %w[opencode cursor gemini].map.with_index do |provider_key, index|
        create(:runner, user: project.effective_owner, runner_key: provider_key, name: "Routed Runner #{index}")
      end
      providers.each do |runner|
        create(:agent_run, :completed, project: project, final_runner: runner.routing_key)
      end

      queries = capture_queries do
        described_class.where(project_id: project.id).distinct_effective_provider_options(account_id: project.account_id)
      end

      provider_queries = queries.grep(/FROM "runners"/)

      expect(provider_queries.size).to eq(1)
    end

    it "omits unresolved routed runner ids from filter options" do
      project = create(:project)
      create(:agent_run, :completed, project: project, final_runner: "runner:999999")

      options = described_class.where(project_id: project.id).distinct_effective_provider_options(account_id: project.account_id)

      expect(options).to be_empty
    end

    it "includes account_id in project-scoped cache key" do
      key = described_class.provider_options_cache_key_for(account_id: 42, project_id: 7)
      expect(key).to include("account/42")
      expect(key).to include("project/7")
    end

    describe "cache invalidation" do
      it "invalidates cache when a new agent run is created" do
        project = create(:project)
        account_key = described_class.provider_options_cache_key_for(account_id: project.account_id)

        described_class.where(project_id: project.id).distinct_effective_provider_options(account_id: project.account_id, cache_key: account_key)
        expect(Rails.cache.read(account_key)).not_to be_nil

        create(:agent_run, project: project, agent_type: "cursor")

        expect(Rails.cache.read(account_key)).to be_nil
      end

      it "invalidates cache when final_runner changes" do
        project = create(:project)
        agent_run = create(:agent_run, :running, project: project, agent_type: "claude_code")
        account_key = described_class.provider_options_cache_key_for(account_id: project.account_id)

        described_class.where(project_id: project.id).distinct_effective_provider_options(account_id: project.account_id, cache_key: account_key)
        expect(Rails.cache.read(account_key)).not_to be_nil

        agent_run.update!(final_runner: "cursor")

        expect(Rails.cache.read(account_key)).to be_nil
      end

      it "does not invalidate cache on intermediate status transitions" do
        project = create(:project)
        agent_run = create(:agent_run, :queued, project: project, agent_type: "claude_code")
        account_key = described_class.provider_options_cache_key_for(account_id: project.account_id)

        described_class.where(project_id: project.id).distinct_effective_provider_options(account_id: project.account_id, cache_key: account_key)
        expect(Rails.cache.read(account_key)).not_to be_nil

        agent_run.update!(status: "running", started_at: Time.current)

        expect(Rails.cache.read(account_key)).not_to be_nil
      end

      it "invalidates both account and project keys on create" do
        project = create(:project)
        account_key = described_class.provider_options_cache_key_for(account_id: project.account_id)
        project_key = described_class.provider_options_cache_key_for(account_id: project.account_id, project_id: project.id)

        Rails.cache.write(account_key, [ "anthropic" ])
        Rails.cache.write(project_key, [ "anthropic" ])

        create(:agent_run, project: project, agent_type: "cursor")

        expect(Rails.cache.read(account_key)).to be_nil
        expect(Rails.cache.read(project_key)).to be_nil
      end

      it "invalidates runner option caches when a routed runner is renamed" do
        project = create(:project)
        runner = create(:runner, user: project.effective_owner, runner_key: "opencode", name: "Kimi K2.5")
        create(:agent_run, project: project, final_runner: runner.routing_key)
        account_key = described_class.provider_options_cache_key_for(account_id: project.account_id)

        described_class.where(project_id: project.id).distinct_effective_provider_options(account_id: project.account_id, cache_key: account_key)
        expect(Rails.cache.read(account_key)).not_to be_nil

        runner.update!(name: "Kimi K2.6")

        expect(Rails.cache.read(account_key)).to be_nil
      end

      it "does not invalidate runner option caches for non-label runner changes" do
        project = create(:project)
        runner = create(:runner, user: project.effective_owner, runner_key: "opencode", name: "Kimi K2.5")
        create(:agent_run, project: project, final_runner: runner.routing_key)
        account_key = described_class.provider_options_cache_key_for(account_id: project.account_id)

        described_class.where(project_id: project.id).distinct_effective_provider_options(account_id: project.account_id, cache_key: account_key)
        expect(Rails.cache.read(account_key)).not_to be_nil

        runner.update!(weight: runner.weight + 1)

        expect(Rails.cache.read(account_key)).not_to be_nil
      end

      it "does not invalidate runner option caches for unrelated config changes" do
        project = create(:project)
        create(:llm_model, model_id: "moonshotai/kimi-k2-0905", provider: "openrouter", tier: "mid")
        runner = create(
          :runner,
          user: project.effective_owner,
          runner_key: "opencode",
          name: "",
          config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0905" } }
        )
        create(:agent_run, project: project, final_runner: runner.routing_key)
        account_key = described_class.provider_options_cache_key_for(account_id: project.account_id)

        described_class.where(project_id: project.id).distinct_effective_provider_options(account_id: project.account_id, cache_key: account_key)
        expect(Rails.cache.read(account_key)).not_to be_nil

        runner.update!(
          config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0905" }, "extra" => "value" }
        )

        expect(Rails.cache.read(account_key)).not_to be_nil
      end

      it "invalidates runner option caches when model-driven display names change" do
        project = create(:project)
        create(:llm_model, model_id: "moonshotai/kimi-k2-0905", provider: "openrouter", tier: "mid")
        create(:llm_model, model_id: "moonshotai/kimi-k2-0906", provider: "openrouter", tier: "mid")
        runner = create(
          :runner,
          user: project.effective_owner,
          runner_key: "opencode",
          name: "",
          config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0905" } }
        )
        create(:agent_run, project: project, final_runner: runner.routing_key)
        account_key = described_class.provider_options_cache_key_for(account_id: project.account_id)

        described_class.where(project_id: project.id).distinct_effective_provider_options(account_id: project.account_id, cache_key: account_key)
        expect(Rails.cache.read(account_key)).not_to be_nil

        runner.update!(
          config: { "opencode" => { "api_provider" => "openrouter", "model" => "moonshotai/kimi-k2-0906" } }
        )

        expect(Rails.cache.read(account_key)).to be_nil
      end

      it "invalidates runner option caches when a runner is discarded" do
        project = create(:project)
        runner = create(:runner, user: project.effective_owner, runner_key: "opencode", name: "Kimi K2.5")
        create(:agent_run, project: project, final_runner: runner.routing_key)
        account_key = described_class.provider_options_cache_key_for(account_id: project.account_id)

        described_class.where(project_id: project.id).distinct_effective_provider_options(account_id: project.account_id, cache_key: account_key)
        expect(Rails.cache.read(account_key)).not_to be_nil

        runner.discard!

        expect(Rails.cache.read(account_key)).to be_nil
      end

      it "invalidates project-scoped runner option caches when a runner label changes" do
        project = create(:project)
        runner = create(:runner, user: project.effective_owner, runner_key: "opencode", name: "Kimi K2.5")
        create(:agent_run, project: project, final_runner: runner.routing_key)
        project_key = described_class.provider_options_cache_key_for(account_id: project.account_id, project_id: project.id)

        described_class.where(project_id: project.id).distinct_effective_provider_options(
          account_id: project.account_id,
          cache_key: project_key
        )
        expect(Rails.cache.read(project_key)).not_to be_nil

        runner.update!(name: "Kimi K2.6")

        expect(Rails.cache.read(project_key)).to be_nil
      end
    end
  end

  describe "#effective_provider" do
    it "returns final_runner when present and not mapped" do
      agent_run = create(:agent_run, agent_type: "claude_code", final_runner: "codex")
      expect(agent_run.effective_provider).to eq("codex")
    end

    it "normalizes final_runner when it contains a legacy agent-type identifier" do
      agent_run = create(:agent_run, agent_type: "cursor", final_runner: "claude_code")
      expect(agent_run.effective_provider).to eq("claude")
    end

    it "returns normalized runner key when final_runner is nil" do
      agent_run = create(:agent_run, agent_type: "claude_code", final_runner: nil)
      expect(agent_run.effective_provider).to eq("claude")
    end

    it "returns normalized runner key when final_runner is blank" do
      agent_run = create(:agent_run, agent_type: "claude_code", final_runner: "")
      expect(agent_run.effective_provider).to eq("claude")
    end

    it "returns agent_type as-is for non-mapped types" do
      agent_run = create(:agent_run, :cursor, final_runner: nil)
      expect(agent_run.effective_provider).to eq("cursor")
    end
  end

  describe ".normalize_provider_sql" do
    it "raises ArgumentError for untrusted column names" do
      expect { described_class.normalize_provider_sql("'; DROP TABLE agent_runs; --") }
        .to raise_error(ArgumentError, /untrusted column/)
    end

    it "accepts whitelisted column names" do
      expect { described_class.normalize_provider_sql("agent_type") }.not_to raise_error
      expect { described_class.normalize_provider_sql("final_runner") }.not_to raise_error
      expect { described_class.normalize_provider_sql("NULLIF(final_runner, '')") }.not_to raise_error
    end
  end

  describe "#final_runner_record" do
    it "resolves a routing-key final runner to its runner record" do
      agent_run = create(:agent_run)
      runner = create(:runner, user: agent_run.project.effective_owner, runner_key: "opencode")
      agent_run.update!(final_runner: runner.routing_key)

      expect(agent_run.final_runner_record).to eq(runner)
    end

    it "returns nil for a non-routing-key final runner" do
      agent_run = create(:agent_run, final_runner: "claude")

      expect(agent_run.final_runner_record).to be_nil
    end

    it "does not resolve providers owned by another user" do
      project_owner = create(:user)
      project = create(:project, account: project_owner.account, created_by: project_owner)
      other_user = create(:user)
      runner = create(:runner, user: other_user, runner_key: "opencode")
      agent_run = create(:agent_run, project: project, final_runner: runner.routing_key)

      expect(agent_run.final_runner_record).to be_nil
    end
  end

  describe "#effective_provider_record" do
    it "returns the final runner record when final_runner is a routing key" do
      agent_run = create(:agent_run)
      runner = create(:runner, user: agent_run.project.effective_owner, runner_key: "opencode")
      agent_run.update!(final_runner: runner.routing_key)

      expect(agent_run.effective_provider_record).to eq(runner)
    end

    it "resolves a subscription provider_key final_runner to its record" do
      agent_run = create(:agent_run)
      owner = agent_run.project.effective_owner
      claude = owner.runners.find_by!(runner_key: "claude", auth_type: "subscription")
      agent_run.update!(final_runner: "claude")

      expect(agent_run.effective_provider_record).to eq(claude)
    end

    it "falls back to the initially-assigned runner when final_runner is blank" do
      agent_run = create(:agent_run)
      owner = agent_run.project.effective_owner
      initial = owner.runners.find_by!(runner_key: "claude", auth_type: "subscription")
      agent_run.update!(runner: initial, final_runner: nil)

      expect(agent_run.effective_provider_record).to eq(initial)
    end

    it "returns nil when neither the final nor initial runner can be resolved" do
      agent_run = create(:agent_run, runner: nil, final_runner: nil)

      expect(agent_run.effective_provider_record).to be_nil
    end
  end

  describe "#attempted_providers_by_routing_key" do
    it "returns attempted providers indexed by routing key" do
      agent_run = create(:agent_run)
      runner = create(:runner, user: agent_run.project.effective_owner, runner_key: "opencode")
      agent_run.update!(
        runners_attempted: [
          { "runner" => runner.routing_key, "success" => false },
          { "runner" => "claude", "success" => true }
        ],
        runner_switches: 1
      )

      expect(agent_run.attempted_providers_by_routing_key).to eq(runner.routing_key => runner)
    end

    it "returns an empty hash when no runner switches were recorded" do
      agent_run = create(:agent_run, runner_switches: 0, runners_attempted: [])

      expect(agent_run.attempted_providers_by_routing_key).to eq({})
    end

    it "ignores attempted providers owned by another user" do
      project_owner = create(:user)
      project = create(:project, account: project_owner.account, created_by: project_owner)
      other_user = create(:user)
      runner = create(:runner, user: other_user, runner_key: "opencode")
      agent_run = create(
        :agent_run,
        project: project,
        runner_switches: 1,
        runners_attempted: [ { "runner" => runner.routing_key, "success" => false } ]
      )

      expect(agent_run.attempted_providers_by_routing_key).to eq({})
    end
  end

  describe "#agent_summary_with_stderr_fallback" do
    let(:agent_run) { create(:agent_run) }

    it "returns stdout when available" do
      agent_run.log!("stdout", "stdout content")
      agent_run.log!("stderr", "stderr content")

      expect(agent_run.agent_summary_with_stderr_fallback).to eq("stdout content")
    end

    it "falls back to stderr when stdout is empty" do
      agent_run.log!("stderr", "stderr content")

      expect(agent_run.agent_summary_with_stderr_fallback).to eq("stderr content")
    end

    it "returns empty string when no logs exist" do
      expect(agent_run.agent_summary_with_stderr_fallback).to eq("")
    end
  end

  describe "#agent_summary JSON envelope stripping" do
    let(:agent_run) { create(:agent_run) }

    it "extracts result text from a Claude CLI JSON envelope" do
      envelope = {
        type: "result",
        subtype: "success",
        is_error: false,
        result: "All done. Here's a summary:\n\n- Fixed the bug\n- Added tests",
        duration_ms: 5000,
        session_id: "abc-123",
        total_cost_usd: 0.05,
        usage: { input_tokens: 100, output_tokens: 50 }
      }.to_json

      agent_run.log!("stdout", envelope)

      expect(agent_run.agent_summary).to eq("All done. Here's a summary:\n\n- Fixed the bug\n- Added tests")
    end

    it "returns raw stdout when it is not a JSON envelope" do
      agent_run.log!("stdout", "Just some plain text output")

      expect(agent_run.agent_summary).to eq("Just some plain text output")
    end

    it "returns raw stdout when JSON is not a CLI envelope" do
      agent_run.log!("stdout", '{"some": "other", "json": true}')

      expect(agent_run.agent_summary).to eq('{"some": "other", "json": true}')
    end

    it "returns raw stdout when envelope result is empty" do
      agent_run.log!("stdout", '{"type":"result","result":"","is_error":false}')

      expect(agent_run.agent_summary).to eq('{"type":"result","result":"","is_error":false}')
    end

    it "surfaces classified error message for is_error envelopes" do
      envelope = {
        type: "result",
        result: "Rate limit exceeded: too many requests",
        is_error: true
      }.to_json

      agent_run.log!("stdout", envelope)

      expect(agent_run.agent_summary).to eq("Agent encountered an error: Rate limit exceeded")
    end

    it "handles multi-chunk stdout that forms a complete JSON envelope" do
      part1 = '{"type":"result","result":"Done","is_error":false'
      part2 = ',"session_id":"abc"}'

      agent_run.log!("stdout", part1)
      agent_run.log!("stdout", part2)

      expect(agent_run.agent_summary).to eq("Done")
    end

    it "strips envelope in agent_summary_with_stderr_fallback too" do
      envelope = { type: "result", result: "Task complete", is_error: false }.to_json
      agent_run.log!("stdout", envelope)
      agent_run.log!("stderr", "some error output")

      expect(agent_run.agent_summary_with_stderr_fallback).to eq("Task complete")
    end

    it "returns empty string when no stdout logs exist" do
      expect(agent_run.agent_summary).to eq("")
    end

    it "extracts text from Codex-style JSONL item.completed events" do
      events = [
        { "type" => "item.completed", "item" => { "type" => "agent_message", "content" => [ { "type" => "output_text", "text" => "Here is my analysis of the codebase." } ] } },
        { "type" => "item.completed", "item" => { "type" => "agent_message", "content" => [ { "type" => "output_text", "text" => "Done. Here's a summary:\n- Fixed the bug\n- Added tests" } ] } }
      ].map(&:to_json).join("\n")

      agent_run.log!("stdout", events)

      expect(agent_run.agent_summary).to eq("Done. Here's a summary:\n- Fixed the bug\n- Added tests")
    end

    it "extracts text from JSONL turn.completed with result" do
      events = [
        { "type" => "message.delta", "delta" => { "content" => [ { "type" => "output_text_delta", "text" => "Working" } ] } },
        { "type" => "turn.completed", "result" => "Final answer from the agent" }
      ].map(&:to_json).join("\n")

      agent_run.log!("stdout", events)

      expect(agent_run.agent_summary).to eq("Final answer from the agent")
    end

    it "extracts text from JSONL agent_message events" do
      events = [
        { "type" => "message.delta", "delta" => {} },
        { "type" => "agent_message", "item_type" => "assistant_message", "content" => [ { "type" => "output_text", "text" => "Agent response text" } ] }
      ].map(&:to_json).join("\n")

      agent_run.log!("stdout", events)

      expect(agent_run.agent_summary).to eq("Agent response text")
    end

    it "extracts text from JSONL event_msg wrapped events" do
      events = [
        { "type" => "message.delta", "delta" => {} },
        { "type" => "event_msg", "payload" => { "type" => "agent_message", "role" => "assistant", "item_type" => "assistant_message", "content" => [ { "type" => "output_text", "text" => "Wrapped response" } ] } }
      ].map(&:to_json).join("\n")

      agent_run.log!("stdout", events)

      expect(agent_run.agent_summary).to eq("Wrapped response")
    end

    it "extracts text from JSONL event_msg wrapped task_complete events" do
      events = [
        { "type" => "message.delta", "delta" => {} },
        { "type" => "event_msg", "payload" => { "type" => "task_complete", "last_agent_message" => "Wrapped final response" } }
      ].map(&:to_json).join("\n")

      agent_run.log!("stdout", events)

      expect(agent_run.agent_summary).to eq("Wrapped final response")
    end

    it "extracts text from JSONL response_item events" do
      events = [
        { "type" => "message.delta", "delta" => {} },
        { "type" => "response_item", "payload" => { "role" => "assistant", "item_type" => "assistant_message", "content" => [ { "type" => "output_text", "text" => "Response item text" } ] } }
      ].map(&:to_json).join("\n")

      agent_run.log!("stdout", events)

      expect(agent_run.agent_summary).to eq("Response item text")
    end

    it "handles JSONL split across multiple log chunks" do
      chunk1 = { "type" => "message.delta", "delta" => {} }.to_json
      chunk2 = { "type" => "item.completed", "item" => { "role" => "assistant", "content" => [ { "type" => "output_text", "text" => "Chunked output" } ] } }.to_json

      agent_run.log!("stdout", chunk1)
      agent_run.log!("stdout", chunk2)

      expect(agent_run.agent_summary).to eq("Chunked output")
    end

    it "returns raw stdout when single-event JSONL has no assistant text" do
      agent_run.log!("stdout", '{"type":"single","data":"value"}')

      expect(agent_run.agent_summary).to eq('{"type":"single","data":"value"}')
    end

    it "extracts text from single-event JSONL turn.completed output" do
      event = { "type" => "turn.completed", "result" => "Single event final answer" }.to_json

      agent_run.log!("stdout", event)

      expect(agent_run.agent_summary).to eq("Single event final answer")
    end

    it "prefers Anthropic envelope when stdout is a single JSON object" do
      envelope = {
        type: "result",
        is_error: false,
        result: "Anthropic result"
      }.to_json

      agent_run.log!("stdout", envelope)

      expect(agent_run.agent_summary).to eq("Anthropic result")
    end

    it "extracts text from JSONL turn.completed with last_agent_message string" do
      events = [
        { "type" => "message.delta", "delta" => {} },
        { "type" => "turn.completed", "last_agent_message" => "Direct string message" }
      ].map(&:to_json).join("\n")

      agent_run.log!("stdout", events)

      expect(agent_run.agent_summary).to eq("Direct string message")
    end

    it "extracts text from JSONL item with text field directly" do
      events = [
        { "type" => "agent_message", "role" => "assistant", "text" => "Direct text field" },
        { "type" => "item.completed", "item" => { "role" => "assistant", "text" => "Item text field" } }
      ].map(&:to_json).join("\n")

      agent_run.log!("stdout", events)

      expect(agent_run.agent_summary).to eq("Item text field")
    end

    it "ignores nil-role JSONL items that are not assistant messages" do
      events = [
        { "type" => "item.completed", "item" => { "type" => "reasoning", "text" => "Private reasoning output" } },
        { "type" => "turn.completed" }
      ].map(&:to_json).join("\n")

      agent_run.log!("stdout", events)

      expect(agent_run.agent_summary).to eq(events)
    end

    it "only scans the most recent 500 JSONL events" do
      stale_line = { "type" => "agent_message", "role" => "assistant", "text" => "Stale output" }.to_json
      events = [
        stale_line,
        *500.times.map { |i| { "type" => "message.delta", "delta" => { "index" => i } }.to_json }
      ].join("\n")

      agent_run.log!("stdout", events)

      parsed_inputs = []
      original_parse = JSON.method(:parse)
      allow(JSON).to receive(:parse) do |input, *args|
        parsed_inputs << input
        original_parse.call(input, *args)
      end

      expect(agent_run.agent_summary).to eq(events)
      expect(parsed_inputs).not_to include(stale_line)
    end

    it "extracts result text from multi-line Claude CLI JSON output" do
      r1 = { type: "result", subtype: "success", is_error: false,
             result: "OK", duration_ms: 2769, total_cost_usd: 0.06 }
      r2 = { type: "result", subtype: "success", is_error: false,
             result: "All done. The commit succeeded.", duration_ms: 830592, total_cost_usd: 0.74 }
      agent_run.log!("stdout", [ r1, r2 ].map(&:to_json).join("\n"))

      expect(agent_run.agent_summary).to eq("OK\n\nAll done. The commit succeeded.")
    end

    it "returns only successful results when mixed with errors in multi-line output" do
      r1 = { type: "result", subtype: "success", is_error: false,
             result: "OK", duration_ms: 2769, total_cost_usd: 0.06 }
      r2 = { type: "result", subtype: "error", is_error: true,
             result: "Authentication failed", duration_ms: 500, total_cost_usd: 0.0 }
      agent_run.log!("stdout", [ r1, r2 ].map(&:to_json).join("\n"))

      expect(agent_run.agent_summary).to eq("OK")
    end

    it "returns error message when all multi-line results are errors" do
      r1 = { type: "result", subtype: "error", is_error: true,
             result: "Authentication failed", duration_ms: 500, total_cost_usd: 0.0 }
      r2 = { type: "result", subtype: "error", is_error: true,
             result: "Retry also failed", duration_ms: 200, total_cost_usd: 0.0 }
      agent_run.log!("stdout", [ r1, r2 ].map(&:to_json).join("\n"))

      expect(agent_run.agent_summary).to eq("Agent encountered an error: Authentication failed")
    end

    it "ignores JSON lines without type: result in multiline fallback" do
      non_result = { type: "agent_message", role: "assistant", result: "should be ignored" }
      result = { type: "result", subtype: "success", is_error: false,
                 result: "Extracted text", duration_ms: 100, total_cost_usd: 0.01 }
      agent_run.log!("stdout", [ non_result, result ].map(&:to_json).join("\n"))

      expect(agent_run.agent_summary).to eq("Extracted text")
    end

    it "extracts error message from type:error JSONL lines" do
      errors = [
        { type: "error", timestamp: 1777909018637, sessionID: "ses_abc",
          error: { name: "UnknownError", data: { message: "Model not found: openai/glm-5.1." } } },
        { type: "error", timestamp: 1777909064953, sessionID: "ses_def",
          error: { name: "UnknownError", data: { message: "Model not found: openai/glm-5.1." } } }
      ].map(&:to_json).join("\n")
      agent_run.log!("stdout", errors)

      expect(agent_run.agent_summary).to eq("Agent encountered an error: Model not found: openai/glm-5.1.")
    end

    it "extracts error message from type:error with message field" do
      error_line = { type: "error", error: { name: "FatalError", message: "Connection refused" } }.to_json
      agent_run.log!("stdout", error_line)

      expect(agent_run.agent_summary).to eq("Agent encountered an error: Connection refused")
    end

    it "extracts error message from type:error with string error" do
      error_line = { type: "error", error: "Something went wrong" }.to_json
      agent_run.log!("stdout", error_line)

      expect(agent_run.agent_summary).to eq("Agent encountered an error: Something went wrong")
    end

    it "extracts error from type:error with top-level message field" do
      error_line = { type: "error", message: "fatal API error" }.to_json
      agent_run.log!("stdout", error_line)

      expect(agent_run.agent_summary).to eq("Agent encountered an error: fatal API error")
    end

    it "prefers result text over error JSONL when both present" do
      mixed = [
        { type: "result", subtype: "success", is_error: false, result: "OK", duration_ms: 100 },
        { type: "error", error: { name: "Warn", data: { message: "Rate limit warning" } } }
      ].map(&:to_json).join("\n")
      agent_run.log!("stdout", mixed)

      expect(agent_run.agent_summary).to eq("OK")
    end

    it "falls through to multiline JSON when structured parser returns blank output" do
      envelope = { type: "result", subtype: "success", is_error: false,
                   result: "OK", duration_ms: 2769, total_cost_usd: 0.06 }.to_json
      mock_provider = instance_double(AgentHarness::Providers::Base)
      allow(AgentHarness).to receive(:provider).and_return(mock_provider)
      allow(mock_provider).to receive(:parse_container_output).and_return(
        double(error: nil, output: "")
      )
      agent_run.log!("stdout", envelope)

      expect(agent_run.agent_summary).to eq("OK")
    end

    it "extracts text from opencode-style type:text JSONL with part.text" do
      events = [
        { type: "step_start", timestamp: 1777913612201, sessionID: "ses_abc",
          part: { id: "prt_1", type: "step-start" } },
        { type: "text", timestamp: 1777913612207, sessionID: "ses_abc",
          part: { id: "prt_2", type: "text", text: "OK",
                  time: { start: 1777913612203, end: 1777913612203 } } },
        { type: "step_finish", timestamp: 1777913612232, sessionID: "ses_abc",
          part: { id: "prt_3", type: "step-finish", reason: "stop" } }
      ].map(&:to_json).join("\n")
      agent_run.log!("stdout", events)

      expect(agent_run.agent_summary).to eq("OK")
    end

    it "extracts text from opencode JSONL ignoring non-text event types" do
      events = [
        { type: "step_start", part: { type: "step-start" } },
        { type: "tool_use", part: { type: "tool", tool: "bash" } },
        { type: "text", part: { type: "text", text: "All done" } },
        { type: "step_finish", part: { type: "step-finish" } }
      ].map(&:to_json).join("\n")
      agent_run.log!("stdout", events)

      expect(agent_run.agent_summary).to eq("All done")
    end
  end

  describe "#current_phase_group" do
    it "returns 'queue' for queued runs" do
      agent_run = create(:agent_run, status: "queued")
      expect(agent_run.current_phase_group).to eq("queue")
    end

    it "returns 'queue' for queued runs with temporal_workflow_id (claimed)" do
      agent_run = create(:agent_run, status: "queued", temporal_workflow_id: "claimed")
      expect(agent_run.current_phase_group).to eq("queue")
    end

    it "returns 'setup' for running runs with no completed phases" do
      agent_run = create(:agent_run, status: "running", started_at: 1.minute.ago)
      expect(agent_run.current_phase_group).to eq("setup")
    end

    it "returns the next phase group after the last completed one" do
      agent_run = create(:agent_run, status: "running", started_at: 5.minutes.ago)
      setup_phase = create(:agent_run_phase, agent_run: agent_run, phase_group: "setup",
        phase_key: "provision_container", started_at: 4.minutes.ago, finished_at: 3.minutes.ago, duration_seconds: 60)
      prompt_phase = create(:agent_run_phase, agent_run: agent_run, phase_group: "prompt",
        phase_key: "prepare_pr_prompt", started_at: 3.minutes.ago, finished_at: 2.minutes.ago, duration_seconds: 60)

      expect(agent_run.current_phase_group(phases: [ setup_phase, prompt_phase ])).to eq("agent")
    end

    it "returns nil for completed runs" do
      agent_run = create(:agent_run, :completed)
      expect(agent_run.current_phase_group).to be_nil
    end

    it "returns nil for failed runs" do
      agent_run = create(:agent_run, status: "failed", started_at: 5.minutes.ago, completed_at: Time.current, duration_seconds: 300)
      expect(agent_run.current_phase_group).to be_nil
    end

    it "returns nil when cleanup is the last completed phase" do
      agent_run = create(:agent_run, status: "running", started_at: 5.minutes.ago)
      cleanup_phase = create(:agent_run_phase, agent_run: agent_run, phase_group: "cleanup",
        phase_key: "cleanup_container", started_at: 2.minutes.ago, finished_at: 1.minute.ago, duration_seconds: 60)

      expect(agent_run.current_phase_group(phases: [ cleanup_phase ])).to be_nil
    end
  end

  describe "#phase_summary" do
    def set_run_timestamps(agent_run, base_time)
      agent_run.update_columns(
        created_at: base_time - 20.minutes,
        started_at: base_time - 10.minutes,
        completed_at: base_time,
        duration_seconds: 600
      )
    end

    def create_phase(agent_run, phase_key:, phase_group:, started_at:, finished_at:, duration_seconds:)
      create(:agent_run_phase, agent_run: agent_run, phase_key: phase_key,
        phase_group: phase_group, started_at: started_at,
        finished_at: finished_at, duration_seconds: duration_seconds)
    end

    def create_default_phase_summary(agent_run, base_time)
      create_phase(agent_run, phase_key: "provision_container", phase_group: "setup",
        started_at: base_time - 15.minutes, finished_at: base_time - 13.minutes, duration_seconds: 120)
      create_phase(agent_run, phase_key: "prepare_pr_prompt", phase_group: "prompt",
        started_at: base_time - 13.minutes, finished_at: base_time - 12.minutes, duration_seconds: 60)
      create_phase(agent_run, phase_key: "run_agent", phase_group: "agent",
        started_at: base_time - 12.minutes, finished_at: base_time - 8.minutes, duration_seconds: 240)
      create_phase(agent_run, phase_key: "create_pull_request", phase_group: "post",
        started_at: base_time - 8.minutes, finished_at: base_time - 7.minutes, duration_seconds: 60)
      create_phase(agent_run, phase_key: "cleanup_container", phase_group: "cleanup",
        started_at: base_time - 7.minutes, finished_at: base_time - 6.minutes, duration_seconds: 60)
    end

    it "summarizes queue and grouped phase durations" do
      agent_run = create(:agent_run, :completed)
      base_time = Time.current
      set_run_timestamps(agent_run, base_time)
      create_default_phase_summary(agent_run, base_time)

      summary = agent_run.reload.phase_summary

      expect(summary[:queue_seconds]).to eq(300)
      expect(summary[:setup_seconds]).to eq(120)
      expect(summary[:prompt_seconds]).to eq(60)
      expect(summary[:agent_seconds]).to eq(240)
      expect(summary[:post_seconds]).to eq(60)
      expect(summary[:cleanup_seconds]).to eq(60)
      expect(summary[:observed_seconds]).to eq(540)
    end
  end

  # Rails 5.0+ fires after_commit callbacks within transactional test fixtures
  # (the test_after_commit gem was absorbed into Rails core). These specs rely
  # on that behavior and work correctly with use_transactional_fixtures = true.
  # We intentionally use after_commit (not after_save) so the job only enqueues
  # after the AgentRun record is visible to other database connections.
  describe "issue goal timeout retry callback" do
    it "enqueues RetryTimedOutIssueGoalJob when an issue goal run transitions to timeout" do
      agent_run = create(:agent_run, :create_issue_goal, status: "running", started_at: 1.hour.ago)

      expect {
        agent_run.update!(status: "timeout", completed_at: Time.current, duration_seconds: 3600)
      }.to have_enqueued_job(RetryTimedOutIssueGoalJob).with(agent_run.id)
    end

    it "does not enqueue for a non-issue-goal run transitioning to timeout" do
      agent_run = create(:agent_run, status: "running", started_at: 1.hour.ago)

      expect {
        agent_run.update!(status: "timeout", completed_at: Time.current, duration_seconds: 3600)
      }.not_to have_enqueued_job(RetryTimedOutIssueGoalJob)
    end

    it "does not enqueue for an issue goal run transitioning to a non-timeout status" do
      agent_run = create(:agent_run, :create_issue_goal, status: "running", started_at: 10.minutes.ago)

      expect {
        agent_run.update!(status: "completed", completed_at: Time.current, duration_seconds: 600)
      }.not_to have_enqueued_job(RetryTimedOutIssueGoalJob)
    end

    it "does not enqueue when updating an issue goal timeout run without status change" do
      agent_run = create(:agent_run, :timeout, :create_issue_goal)

      expect {
        agent_run.update!(branch_name: "feature/test")
      }.not_to have_enqueued_job(RetryTimedOutIssueGoalJob)
    end
  end

  describe "container metrics collection callback" do
    it "enqueues ContainerMetricsCollectionJob when transitioning to running with container_id" do
      agent_run = create(:agent_run, :queued, container_id: "abc123")

      expect {
        agent_run.update!(status: "running", started_at: Time.current)
      }.to have_enqueued_job(ContainerMetricsCollectionJob).with(agent_run.id)
    end

    it "does not enqueue when transitioning to running without container_id" do
      agent_run = create(:agent_run, :queued, container_id: nil)

      expect {
        agent_run.update!(status: "running", started_at: Time.current)
      }.not_to have_enqueued_job(ContainerMetricsCollectionJob)
    end

    it "does not enqueue when transitioning to a non-running status" do
      agent_run = create(:agent_run, :running, container_id: "abc123")

      expect {
        agent_run.update!(status: "completed", completed_at: Time.current, duration_seconds: 10)
      }.not_to have_enqueued_job(ContainerMetricsCollectionJob)
    end

    it "does not enqueue when updating a running run without status change" do
      agent_run = create(:agent_run, :running, container_id: "abc123")

      expect {
        agent_run.update!(branch_name: "feature/test")
      }.not_to have_enqueued_job(ContainerMetricsCollectionJob)
    end
  end

  describe "failure recovery callback" do
    it "enqueues failure recovery when transitioning to a failure status" do
      agent_run = create(:agent_run, :running, error_message: nil)

      expect {
        agent_run.fail!(error: "RateLimit: exceeded quota")
      }.to have_enqueued_job(FailureRecoveryDecisionJob).with(
        agent_run.id,
        hash_including(
          "status" => "failed",
          "error_message" => "RateLimit: exceeded quota"
        )
      )
    end

    it "enqueues failure recovery when transitioning to completed" do
      agent_run = create(:agent_run, :running, started_at: 1.minute.ago)

      expect {
        agent_run.complete!
      }.to have_enqueued_job(FailureRecoveryDecisionJob).with(
        agent_run.id,
        hash_including("status" => "completed")
      )
    end

    it "captures the timeout status in the enqueued snapshot" do
      agent_run = create(:agent_run, :running, goal: "create_issue")

      expect {
        agent_run.update!(status: "timeout", error_message: "Agent execution timed out")
      }.to have_enqueued_job(FailureRecoveryDecisionJob).with(
        agent_run.id,
        hash_including(
          "status" => "timeout",
          "error_message" => "Agent execution timed out"
        )
      )
    end

    it "captures guardrail subtype in the timeout snapshot" do
      agent_run = create(:agent_run, :running, goal: "create_issue")

      expect {
        agent_run.timeout!(
          error: "guardrail: time_limit — Execution exceeded 3600s limit",
          guardrail_violation_type: "time_limit",
          guardrail_context: { violation_type: "time_limit", details: "Execution exceeded 3600s limit" }
        )
      }.to have_enqueued_job(FailureRecoveryDecisionJob).with(
        agent_run.id,
        hash_including(
          "status" => "timeout",
          "error_message" => "guardrail: time_limit — Execution exceeded 3600s limit",
          "guardrail_violation_type" => "time_limit"
        )
      )
    end

    it "does not enqueue failure recovery for retried transitions" do
      agent_run = create(:agent_run, :failed)

      expect {
        agent_run.retry!
      }.not_to have_enqueued_job(FailureRecoveryDecisionJob)
    end

    it "does not enqueue failure recovery when status does not change" do
      agent_run = create(:agent_run, :running)

      expect {
        agent_run.update!(branch_name: "feature/test")
      }.not_to have_enqueued_job(FailureRecoveryDecisionJob)
    end
  end

  describe "dispatch circuit breaker outcome callback" do
    let(:project) { create(:project) }
    let(:account) { project.account }

    it "enqueues DispatchCircuitBreakerOutcomeJob with success on a completed transition" do
      agent_run = create(:agent_run, :running, project: project, final_runner: "claude")

      expect {
        agent_run.complete!
      }.to have_enqueued_job(DispatchCircuitBreakerOutcomeJob).with(
        account_id: account.id,
        success: true,
        agent_run_id: agent_run.id
      )
    end

    it "enqueues DispatchCircuitBreakerOutcomeJob with success on a no_output transition" do
      agent_run = create(:agent_run, :running, project: project, final_runner: "claude")

      expect {
        agent_run.complete_no_output!(reason: "no_changes")
      }.to have_enqueued_job(DispatchCircuitBreakerOutcomeJob).with(
        account_id: account.id,
        success: true,
        agent_run_id: agent_run.id
      )
    end

    it "enqueues DispatchCircuitBreakerOutcomeJob with failure on a failed transition" do
      agent_run = create(:agent_run, :running, project: project, final_runner: "claude")

      expect {
        agent_run.fail!(error: "boom")
      }.to have_enqueued_job(DispatchCircuitBreakerOutcomeJob).with(
        account_id: account.id,
        success: false,
        agent_run_id: agent_run.id
      )
    end

    it "does not enqueue when final_runner is blank" do
      agent_run = create(:agent_run, :running, project: project, final_runner: nil)

      expect {
        agent_run.complete!
      }.not_to have_enqueued_job(DispatchCircuitBreakerOutcomeJob)
    end

    it "does not enqueue for non-terminal status changes" do
      agent_run = create(:agent_run, :running, project: project, final_runner: "claude")

      expect {
        agent_run.update!(branch_name: "feature/test")
      }.not_to have_enqueued_job(DispatchCircuitBreakerOutcomeJob)
    end
  end

  describe "#pause!" do
    it "transitions a running run to paused with violation context" do
      agent_run = create(:agent_run, :running)
      context = { violation_type: "loop_detected", details: "test" }

      agent_run.pause!(violation_type: "loop_detected", context: context)

      agent_run.reload
      expect(agent_run.status).to eq("paused")
      expect(agent_run.paused_at).to be_present
      expect(agent_run.guardrail_violation_type).to eq("loop_detected")
      expect(agent_run.guardrail_context).to eq(context.deep_stringify_keys)
    end

    it "records a pause decision event" do
      agent_run = create(:agent_run, :running)

      expect {
        agent_run.pause!(violation_type: "loop_detected", context: { details: "test" })
      }.to change(OrchestrationDecision, :count).by(1)

      event = OrchestrationDecision.last
      expect(event.decision_type).to eq("pause")
      expect(event.context["decision_status"]).to eq("applied")
      expect(event.inputs).to include("violation_type" => "loop_detected")
    end

    it "does not pause a non-running run" do
      agent_run = create(:agent_run, :completed)

      expect {
        agent_run.pause!(violation_type: "loop_detected")
      }.to change(OrchestrationDecision, :count).by(1)

      expect(agent_run.reload.status).to eq("completed")
      expect(OrchestrationDecision.last.context["decision_status"]).to eq("noop")
    end

    it "still pauses the run when decision logging fails" do
      agent_run = create(:agent_run, :running)
      allow(OrchestrationDecision).to receive(:record!).and_raise(ActiveRecord::StatementInvalid, "boom")

      expect(agent_run.pause!(violation_type: "loop_detected")).to be true

      expect(agent_run.reload.status).to eq("paused")
    end
  end

  describe "#resume!" do
    def build_resumable_paused_run
      agent_run = create(:agent_run, :running)
      agent_run.pause!(violation_type: "loop_detected", context: { details: "test" })
      agent_run.update!(
        queue_entered_at: 2.hours.ago,
        temporal_workflow_id: "workflow-123",
        temporal_run_id: "run-123",
        started_at: 10.minutes.ago,
        completed_at: 5.minutes.ago,
        duration_seconds: 300
      )
      agent_run
    end

    it "transitions a paused run back to queued" do
      agent_run = build_resumable_paused_run
      frozen_now = nil

      freeze_time do
        frozen_now = Time.current
        agent_run.resume!
      end

      agent_run.reload
      expect(agent_run.status).to eq("queued")
      expect(agent_run.queue_entered_at).to be_within(1.second).of(frozen_now)
      expect(agent_run.started_at).to be_nil
      expect(agent_run.completed_at).to be_nil
      expect(agent_run.duration_seconds).to be_nil
      expect(agent_run.paused_at).to be_nil
      expect(agent_run.guardrail_violation_type).to be_nil
      expect(agent_run.guardrail_context).to be_nil
      expect(agent_run.temporal_workflow_id).to be_nil
      expect(agent_run.temporal_run_id).to be_nil
    end

    it "returns true for paused runs" do
      expect(build_resumable_paused_run.resume!).to be true
    end

    it "refreshes queue_entered_at when resuming" do
      agent_run = build_resumable_paused_run
      frozen_now = nil

      freeze_time do
        frozen_now = Time.current
        agent_run.resume!
      end

      expect(agent_run.reload.queue_entered_at).to be_within(1.second).of(frozen_now)
    end

    it "records a resume decision event" do
      agent_run = create(:agent_run, :running)
      agent_run.pause!(violation_type: "loop_detected", context: { details: "test" })

      expect {
        agent_run.resume!(decision_point: "manual_resume")
      }.to change(OrchestrationDecision, :count).by(1)

      event = OrchestrationDecision.last
      expect(event.decision_type).to eq("resume")
      expect(event.context["decision_status"]).to eq("applied")
      expect(event.actor).to eq("manual_resume")
    end

    it "does not resume a non-paused run" do
      agent_run = create(:agent_run, :running)

      expect {
        expect(agent_run.resume!).to be false
      }.to change(OrchestrationDecision, :count).by(1)

      expect(agent_run.reload.status).to eq("running")
      expect(OrchestrationDecision.last.context["decision_status"]).to eq("noop")
    end

    it "still resumes the run when decision logging fails" do
      agent_run = create(:agent_run, :running)
      agent_run.pause!(violation_type: "loop_detected", context: { details: "test" })
      allow(OrchestrationDecision).to receive(:record!).and_raise(ActiveRecord::StatementInvalid, "boom")

      expect(agent_run.resume!).to be true

      expect(agent_run.reload.status).to eq("queued")
    end
  end

  describe "#queue_entered_at_for_current_episode" do
    it "falls back to created_at when queue_entered_at is missing" do
      queued_run = build(:agent_run, status: "queued", queue_entered_at: nil, created_at: 5.minutes.ago)

      expect(queued_run.queue_entered_at_for_current_episode).to eq(queued_run.created_at)
    end
  end

  describe "#paused?" do
    it "returns true for paused runs" do
      agent_run = build(:agent_run, status: "paused")

      expect(agent_run.paused?).to be true
    end

    it "returns false for running runs" do
      agent_run = build(:agent_run, status: "running")

      expect(agent_run.paused?).to be false
    end
  end

  describe "guardrail_violation_type validation" do
    it "accepts valid violation types" do
      AgentRun::GUARDRAIL_VIOLATION_TYPES.each do |type|
        agent_run = build(:agent_run, guardrail_violation_type: type)
        agent_run.valid?
        expect(agent_run.errors[:guardrail_violation_type]).to be_empty
      end
    end

    it "rejects invalid violation types" do
      agent_run = build(:agent_run, guardrail_violation_type: "invalid_type")

      expect(agent_run).not_to be_valid
      expect(agent_run.errors[:guardrail_violation_type]).to be_present
    end

    it "allows nil violation type" do
      agent_run = build(:agent_run, guardrail_violation_type: nil)
      agent_run.valid?

      expect(agent_run.errors[:guardrail_violation_type]).to be_empty
    end
  end

  describe "streaming turn metrics" do
    describe "#streaming_total_tokens" do
      it "sums tokens across all turns" do
        agent_run = create(:agent_run, streaming_turns_data: [
          { "turn_number" => 1, "input_tokens" => 500, "output_tokens" => 200 },
          { "turn_number" => 2, "input_tokens" => 300, "output_tokens" => 100 }
        ])

        expect(agent_run.streaming_total_tokens).to eq(1100)
      end

      it "returns 0 for empty turns data" do
        agent_run = create(:agent_run, streaming_turns_data: [])
        expect(agent_run.streaming_total_tokens).to eq(0)
      end

      it "handles missing token fields gracefully" do
        agent_run = create(:agent_run, streaming_turns_data: [
          { "turn_number" => 1 }
        ])

        expect(agent_run.streaming_total_tokens).to eq(0)
      end

      it "returns 0 when turns data is nil" do
        agent_run = build(:agent_run, streaming_turns_data: nil)

        expect(agent_run.streaming_total_tokens).to eq(0)
      end
    end

    describe "#streaming_avg_tokens_per_turn" do
      it "calculates average tokens per turn" do
        agent_run = create(:agent_run, turns_completed: 2, streaming_turns_data: [
          { "turn_number" => 1, "input_tokens" => 500, "output_tokens" => 200 },
          { "turn_number" => 2, "input_tokens" => 300, "output_tokens" => 100 }
        ])

        expect(agent_run.streaming_avg_tokens_per_turn).to eq(550.0)
      end

      it "returns 0 when no turns completed" do
        agent_run = create(:agent_run, turns_completed: 0, streaming_turns_data: [])
        expect(agent_run.streaming_avg_tokens_per_turn).to eq(0)
      end

      it "returns 0 when turns_completed is nil" do
        agent_run = build(:agent_run, turns_completed: nil, streaming_turns_data: nil)

        expect(agent_run.streaming_avg_tokens_per_turn).to eq(0)
      end
    end

    describe "validations" do
      it "validates turns_completed is non-negative" do
        agent_run = build(:agent_run, turns_completed: -1)
        expect(agent_run).not_to be_valid
        expect(agent_run.errors[:turns_completed]).to be_present
      end

      it "validates turns_completed is an integer" do
        agent_run = build(:agent_run, turns_completed: 5)
        expect(agent_run).to be_valid
      end
    end
  end

  describe "counter caches" do
    let(:project) { create(:project) }
    let(:inserted_agent_run_timestamp) { Time.current }

    def insert_agent_run_without_callbacks(project:, status:, now:)
      attributes = {
        project_id: project.id,
        issue_id: create(:issue, project: project).id,
        agent_type: "claude_code",
        status: status,
        goal: "create_pr",
        trigger_type: "manual",
        proxy_token: SecureRandom.hex(32),
        created_at: now,
        updated_at: now
      }

      if status == "completed"
        attributes.merge!(
          started_at: now - 10.minutes,
          completed_at: now,
          duration_seconds: 600,
          result_commit_sha: "abc123def456789012345678901234567890abcd",
          pull_request_url: "https://github.com/example/repo/pull/1",
          pull_request_number: 1
        )
      end

      result = described_class.insert_all!([ attributes ], returning: %w[id])
      described_class.find(result.rows.first.first)
    end

    describe "agent_runs_count" do
      it "increments on create" do
        expect { create(:agent_run, project: project) }
          .to change { project.reload.agent_runs_count }.by(1)
      end

      it "decrements on destroy" do
        agent_run = create(:agent_run, project: project)
        expect { agent_run.destroy! }
          .to change { project.reload.agent_runs_count }.by(-1)
      end

      it "stays accurate when a run inserted with insert_all! (with manual increment) is later destroyed" do
        agent_run = insert_agent_run_without_callbacks(
          project: project,
          status: "queued",
          now: inserted_agent_run_timestamp
        )
        # Real callers (e.g. Runners::TestAgent) manually increment after insert_all!
        Project.update_counters(project.id, agent_runs_count: 1)

        expect { agent_run.destroy! }
          .to change { project.reload.agent_runs_count }.from(1).to(0)
      end
    end

    describe "completed_agent_runs_count" do
      it "does not change when a non-completed run is created" do
        expect { create(:agent_run, project: project, status: "queued") }
          .not_to change { project.reload.completed_agent_runs_count }
      end

      it "increments when a run is created already completed" do
        expect { create(:agent_run, :completed, project: project) }
          .to change { project.reload.completed_agent_runs_count }.by(1)
      end

      it "increments when a run transitions to completed" do
        agent_run = create(:agent_run, :running, project: project)
        expect { agent_run.update!(status: "completed", completed_at: Time.current) }
          .to change { project.reload.completed_agent_runs_count }.by(1)
      end

      it "decrements when a run transitions from completed to another status" do
        agent_run = create(:agent_run, :running, project: project)
        agent_run.update!(status: "completed", completed_at: Time.current)
        project.reload
        expect { agent_run.update!(status: "failed") }
          .to change { project.reload.completed_agent_runs_count }.by(-1)
      end

      it "does not change on status transitions not involving completed" do
        agent_run = create(:agent_run, project: project, status: "queued")
        expect { agent_run.update!(status: "running", started_at: Time.current) }
          .not_to change { project.reload.completed_agent_runs_count }
      end

      it "decrements when a completed run is destroyed" do
        agent_run = create(:agent_run, :running, project: project)
        agent_run.update!(status: "completed", completed_at: Time.current)
        project.reload
        expect { agent_run.destroy! }
          .to change { project.reload.completed_agent_runs_count }.by(-1)
      end

      it "stays accurate when a completed run inserted with insert_all! (with manual increment) is later destroyed" do
        agent_run = insert_agent_run_without_callbacks(
          project: project,
          status: "completed",
          now: inserted_agent_run_timestamp
        )
        # Real callers manually increment after insert_all!
        Project.update_counters(project.id, agent_runs_count: 1, completed_agent_runs_count: 1)

        expect { agent_run.destroy! }
          .to change { project.reload.completed_agent_runs_count }.from(1).to(0)
      end

      it "refreshes a previously loaded project association before broadcasting stats" do
        agent_run = create(:agent_run, :running, project: project)
        loaded_project = agent_run.project

        agent_run.update!(status: "completed", completed_at: Time.current)

        expect(agent_run.project).to equal(loaded_project)
        expect(agent_run.project.completed_agent_runs_count).to eq(1)
      end
    end

    describe "#cleanup_orphaned_workspace_volume" do
      let(:agent_run) { create(:agent_run, container_host: "remote", worktree_path: nil) }
      let(:backend) { instance_double(Containers::Backends::Base) }
      let(:volume) { instance_double(Docker::Volume) }

      it "uses the persisted container host backend for volume cleanup" do
        allow(Containers).to receive(:backend_for).with("remote").and_return(backend)
        allow(backend).to receive(:get_volume).with("paid-workspace-#{agent_run.id}", host: "remote").and_return(volume)
        allow(backend).to receive(:delete_volume).with(volume)

        agent_run.send(:cleanup_orphaned_workspace_volume)

        expect(Containers).to have_received(:backend_for).with("remote")
        expect(backend).to have_received(:get_volume).with("paid-workspace-#{agent_run.id}", host: "remote")
        expect(backend).to have_received(:delete_volume).with(volume)
      end
    end
  end
end
