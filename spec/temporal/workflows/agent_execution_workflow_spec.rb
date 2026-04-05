# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::AgentExecutionWorkflow do
  let(:workflow) { described_class.new }

  describe "class" do
    it "inherits from BaseWorkflow" do
      expect(described_class.superclass).to eq(Workflows::BaseWorkflow)
    end

    it "is a Temporal workflow definition" do
      expect(described_class).to be < Temporalio::Workflow::Definition
    end
  end

  describe "#execute" do
    it "accepts a single input parameter" do
      params = workflow.method(:execute).parameters
      expect(params).to eq([ [ :req, :input ] ])
    end
  end

  describe "NO_RETRY" do
    it "defines a no-retry policy with max_attempts of 1" do
      policy = described_class::NO_RETRY
      expect(policy).to be_a(Temporalio::RetryPolicy)
      expect(policy.max_attempts).to eq(1)
    end
  end

  describe "CLEANUP_RETRY_POLICY" do
    it "defines a retry policy with 5 attempts and backoff" do
      policy = described_class::CLEANUP_RETRY_POLICY
      expect(policy).to be_a(Temporalio::RetryPolicy)
      expect(policy.max_attempts).to eq(5)
      expect(policy.initial_interval).to eq(2)
      expect(policy.backoff_coefficient).to eq(2)
    end
  end

  describe "create_issue fallback" do
    let(:input) { { project_id: 1, issue_id: 1, goal: "create_issue" } }

    before do
      allow(Rails.application.config.x).to receive(:agent_timeout).and_return(600)
      allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger, patched: true)
    end

    def stub_issue_activities(issue_created:)
      allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
        case activity_class.name
        when "Activities::CreateAgentRunActivity" then { agent_run_id: 42 }
        when "Activities::RunAgentActivity" then { success: true }
        when "Activities::CompleteIssueGoalActivity"
          { agent_run_id: 42, success: true, issue_created: issue_created }
        when "Activities::CreateGithubIssueActivity"
          { agent_run_id: 42, issue_url: "https://github.com/o/r/issues/1", issue_number: 1 }
        else {}
        end
      end
    end

    it "runs CreateGithubIssueActivity when CompleteIssueGoalActivity returns issue_created: false" do
      stub_issue_activities(issue_created: false)

      result = workflow.execute(input)

      expect(result[:success]).to be true
      expect(workflow).to have_received(:run_activity)
        .with(Activities::CreateGithubIssueActivity, { agent_run_id: 42 },
              timeout: 120, retry_policy: described_class::NO_RETRY)
    end

    it "skips CreateGithubIssueActivity when CompleteIssueGoalActivity returns issue_created: true" do
      stub_issue_activities(issue_created: true)

      result = workflow.execute(input)

      expect(result[:success]).to be true
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::CreateGithubIssueActivity, anything,
              timeout: anything, retry_policy: anything)
    end
  end

  describe "activity timeout for create_issue goal" do
    let(:input) { { project_id: 1, issue_id: 1, goal: "create_issue" } }

    before do
      allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger, patched: true)
    end

    it "uses shorter start_to_close_timeout for create_issue goals" do
      allow(workflow).to receive(:run_activity) do |activity_class, _input, **opts|
        case activity_class.name
        when "Activities::CreateAgentRunActivity" then { agent_run_id: 42, provider_attempt_count: 3, agent_timeout_seconds: AGENT_TIMEOUT_DEFAULT, issue_goal_timeout_seconds: Activities::RunAgentActivity::DEFAULT_ISSUE_GOAL_TIMEOUT }
        when "Activities::RunAgentActivity"
          expected_timeout = (Activities::RunAgentActivity::DEFAULT_ISSUE_GOAL_TIMEOUT * 3) + 300
          expect(opts[:start_to_close_timeout]).to eq(expected_timeout)
          { success: true }
        when "Activities::CompleteIssueGoalActivity"
          { agent_run_id: 42, success: true, issue_created: true }
        else {}
        end
      end

      workflow.execute(input)
    end

    it "falls back to defaults when CreateAgentRunActivity omits timeout keys (replay compatibility)" do
      allow(workflow).to receive(:run_activity) do |activity_class, _input, **opts|
        case activity_class.name
        when "Activities::CreateAgentRunActivity" then { agent_run_id: 42 }
        when "Activities::RunAgentActivity"
          expected_timeout = (Activities::RunAgentActivity::DEFAULT_ISSUE_GOAL_TIMEOUT * 1) + 300
          expect(opts[:start_to_close_timeout]).to eq(expected_timeout)
          { success: true }
        when "Activities::CompleteIssueGoalActivity"
          { agent_run_id: 42, success: true, issue_created: true }
        else {}
        end
      end

      workflow.execute(input)
    end
  end

  describe "review goal" do
    let(:input) { { project_id: 1, issue_id: 1, goal: "review", source_pull_request_number: 42 } }

    before do
      allow(Rails.application.config.x).to receive(:agent_timeout).and_return(3600)
      allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger, patched: true)
    end

    def stub_review_activities
      allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
        case activity_class.name
        when "Activities::CreateAgentRunActivity" then { agent_run_id: 42 }
        when "Activities::RunAgentActivity" then { success: true }
        when "Activities::CompleteReviewGoalActivity" then { agent_run_id: 42, success: true }
        else {}
        end
      end
    end

    it "runs CompleteReviewGoalActivity after a successful agent run" do
      stub_review_activities

      result = workflow.execute(input)

      expect(result[:success]).to be true
      expect(workflow).to have_received(:run_activity)
        .with(Activities::CompleteReviewGoalActivity, { agent_run_id: 42 },
              timeout: 30, retry_policy: described_class::NO_RETRY)
    end

    it "does not run PR creation or push activities" do
      stub_review_activities

      workflow.execute(input)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::CreatePullRequestActivity, anything, timeout: anything)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::PushBranchActivity, anything, timeout: anything)
    end

    it "does not run PreparePrPromptActivity for review goals" do
      stub_review_activities

      workflow.execute(input)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::PreparePrPromptActivity, anything, timeout: anything)
    end

    it "does not run RebaseBranchActivity for review goals" do
      stub_review_activities

      workflow.execute(input)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::RebaseBranchActivity, anything, timeout: anything)
    end
  end

  describe "RUN_AGENT_RETRY_POLICY" do
    it "allows 2 attempts for infrastructure-level recovery" do
      policy = described_class::RUN_AGENT_RETRY_POLICY
      expect(policy).to be_a(Temporalio::RetryPolicy)
      expect(policy.max_attempts).to eq(2)
    end
  end

  describe "heartbeat_timeout and retry_policy for RunAgentActivity" do
    let(:input) { { project_id: 1, issue_id: 1, goal: "create_pr" } }

    before do
      allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger, patched: true)
    end

    it "configures heartbeat_timeout and RUN_AGENT_RETRY_POLICY on RunAgentActivity" do
      allow(workflow).to receive(:run_activity) do |activity_class, _input, **opts|
        case activity_class.name
        when "Activities::CreateAgentRunActivity" then { agent_run_id: 42 }
        when "Activities::RunAgentActivity"
          expect(opts[:heartbeat_timeout]).to eq(120)
          expect(opts[:retry_policy]).to eq(described_class::RUN_AGENT_RETRY_POLICY)
          { success: true, has_changes: false }
        when "Activities::MarkAgentRunCompleteActivity" then {}
        else {}
        end
      end

      workflow.execute(input)
    end
  end

  describe "activity timeout for create_pr goal" do
    let(:input) { { project_id: 1, issue_id: 1, goal: "create_pr" } }

    before do
      allow(Rails.application.config.x).to receive(:agent_timeout).and_return(3600)
      allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger, patched: true)
    end

    it "uses default agent_timeout for create_pr goals" do
      allow(workflow).to receive(:run_activity) do |activity_class, _input, **opts|
        case activity_class.name
        when "Activities::CreateAgentRunActivity" then { agent_run_id: 42, provider_attempt_count: 3 }
        when "Activities::RunAgentActivity"
          expect(opts[:start_to_close_timeout]).to eq(11_100) # (3600 * 3 attempts) + 300
          { success: true, has_changes: false }
        when "Activities::MarkAgentRunCompleteActivity" then {}
        else {}
        end
      end

      workflow.execute(input)
    end
  end

  describe "max_execution_seconds timeout capping" do
    let(:input) { { project_id: 1, issue_id: 1, goal: "create_pr" } }

    before do
      allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger, patched: true)
    end

    it "caps activity timeout by max_execution_seconds when it is smaller" do
      allow(workflow).to receive(:run_activity) do |activity_class, _input, **opts|
        case activity_class.name
        when "Activities::CreateAgentRunActivity"
          { agent_run_id: 42, provider_attempt_count: 3, agent_timeout_seconds: 3600, max_execution_seconds: 1800 }
        when "Activities::RunAgentActivity"
          # Without cap: (3600 * 3) + 300 = 11_100
          # With cap: 1800 + 300 = 2100
          expect(opts[:start_to_close_timeout]).to eq(2100)
          { success: true, has_changes: false }
        when "Activities::MarkAgentRunCompleteActivity" then {}
        else {}
        end
      end

      workflow.execute(input)
    end

    it "does not cap when max_execution_seconds is larger than computed timeout" do
      allow(workflow).to receive(:run_activity) do |activity_class, _input, **opts|
        case activity_class.name
        when "Activities::CreateAgentRunActivity"
          { agent_run_id: 42, provider_attempt_count: 1, agent_timeout_seconds: 1800, max_execution_seconds: 86_400 }
        when "Activities::RunAgentActivity"
          # Computed: (1800 * 1) + 300 = 2100
          # Cap: 86_400 + 300 = 86_700 (larger, so no cap)
          expect(opts[:start_to_close_timeout]).to eq(2100)
          { success: true, has_changes: false }
        when "Activities::MarkAgentRunCompleteActivity" then {}
        else {}
        end
      end

      workflow.execute(input)
    end

    it "does not cap when max_execution_seconds is nil" do
      allow(workflow).to receive(:run_activity) do |activity_class, _input, **opts|
        case activity_class.name
        when "Activities::CreateAgentRunActivity"
          { agent_run_id: 42, provider_attempt_count: 1, agent_timeout_seconds: 3600, max_execution_seconds: nil }
        when "Activities::RunAgentActivity"
          expect(opts[:start_to_close_timeout]).to eq(3900)
          { success: true, has_changes: false }
        when "Activities::MarkAgentRunCompleteActivity" then {}
        else {}
        end
      end

      workflow.execute(input)
    end
  end

  describe "existing PR follow-up reviews" do
    let(:input) { { project_id: 1, issue_id: 1, source_pull_request_number: 42 } }

    before do
      allow(Rails.application.config.x).to receive(:agent_timeout).and_return(3600)
      allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger, patched: true)
    end

    def stub_existing_pr_followup(pr_review_phase:)
      allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
        case activity_class.name
        when "Activities::CreateAgentRunActivity" then { agent_run_id: 42, provider_attempt_count: 1 }
        when "Activities::ProvisionServicesActivity" then {}
        when "Activities::ProvisionContainerActivity" then {}
        when "Activities::CloneRepoActivity" then {}
        when "Activities::RebaseBranchActivity" then { rebase_succeeded: true }
        when "Activities::PreparePrPromptActivity" then {}
        when "Activities::RunAgentActivity" then { success: true, has_changes: true }
        when "Activities::PushBranchActivity" then {}
        when "Activities::ResolveReviewThreadsActivity" then {}
        when "Activities::CompleteExistingPrRunActivity" then { pr_review_phase: pr_review_phase }
        when "Activities::ResolvePrReviewPlanActivity" then { requested_review_methods: [ "copilot", "paid_agent" ] }
        when "Activities::RequestReviewActivity" then {}
        when "Activities::QueueAgentRunActivity" then {}
        when "Activities::CleanupContainerActivity" then {}
        when "Activities::CleanupServicesActivity" then {}
        when "Activities::CleanupWorktreeActivity" then {}
        else {}
        end
      end
    end

    it "re-requests configured reviews after pushing commits to a ready PR" do
      stub_existing_pr_followup(pr_review_phase: "ready")

      workflow.execute(input)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity,
          { project_id: 1, pr_number: 42,
            reviewers: [ Activities::RequestReviewActivity::COPILOT_LOGIN ] },
          timeout: 60)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          { project_id: 1, source_pull_request_number: 42, goal: "review" },
          timeout: 30)
    end

    it "does not request configured reviews after pushing commits to a merged PR" do
      stub_existing_pr_followup(pr_review_phase: "merged")

      workflow.execute(input)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::RequestReviewActivity, any_args)
    end

    it "still queues paid_agent review when copilot request fails" do
      stub_existing_pr_followup(pr_review_phase: "ready")
      allow(workflow).to receive(:run_activity)
        .with(Activities::RequestReviewActivity, anything, timeout: anything)
        .and_raise(StandardError, "copilot unavailable")

      workflow.execute(input)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          { project_id: 1, source_pull_request_number: 42, goal: "review" },
          timeout: 30)
    end
  end

  describe "existing PR follow-up with no changes" do
    let(:input) { { project_id: 1, issue_id: 1, source_pull_request_number: 42 } }

    before do
      allow(Rails.application.config.x).to receive(:agent_timeout).and_return(3600)
      allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger, patched: true)
    end

    def stub_no_changes_followup
      allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
        case activity_class.name
        when "Activities::CreateAgentRunActivity" then { agent_run_id: 42, provider_attempt_count: 1 }
        when "Activities::ProvisionServicesActivity" then {}
        when "Activities::ProvisionContainerActivity" then {}
        when "Activities::CloneRepoActivity" then {}
        when "Activities::RebaseBranchActivity" then { rebase_succeeded: true }
        when "Activities::PreparePrPromptActivity" then {}
        when "Activities::RunAgentActivity" then { success: true, has_changes: false }
        when "Activities::MarkAgentRunCompleteActivity" then {}
        when "Activities::ResolvePrReviewPlanActivity" then { requested_review_methods: [ "copilot", "paid_agent" ] }
        when "Activities::RequestReviewActivity" then {}
        when "Activities::QueueAgentRunActivity" then {}
        when "Activities::CleanupContainerActivity" then {}
        when "Activities::CleanupServicesActivity" then {}
        when "Activities::CleanupWorktreeActivity" then {}
        else {}
        end
      end
    end

    it "requests configured reviews even when agent makes no changes on existing PR" do
      stub_no_changes_followup

      workflow.execute(input)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity,
          { project_id: 1, pr_number: 42,
            reviewers: [ Activities::RequestReviewActivity::COPILOT_LOGIN ] },
          timeout: 60)
      expect(workflow).to have_received(:run_activity)
        .with(Activities::QueueAgentRunActivity,
          { project_id: 1, source_pull_request_number: 42, goal: "review" },
          timeout: 30)
    end
  end

  describe "configured review request patch guard" do
    before do
      allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger, patched: false)
      allow(workflow).to receive(:run_activity)
    end

    it "preserves the legacy copilot request path when the patch is disabled" do
      workflow.send(:request_configured_reviews, 1, 42)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity,
          { project_id: 1, pr_number: 42,
            reviewers: [ Activities::RequestReviewActivity::COPILOT_LOGIN ] }, timeout: 60)
      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::ResolvePrReviewPlanActivity, any_args)
    end
  end

  describe "ensure block cleanup and janitor enqueue" do
    let(:input) { { project_id: 1, issue_id: 1 } }

    before do
      allow(Rails.application.config.x).to receive(:agent_timeout).and_return(3600)
      allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger, patched: true)
    end

    def stub_successful_run
      allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
        case activity_class.name
        when "Activities::CreateAgentRunActivity" then { agent_run_id: 42 }
        when "Activities::RunAgentActivity" then { success: true, has_changes: false }
        when "Activities::MarkAgentRunCompleteActivity" then {}
        when "Activities::CleanupContainerActivity" then {}
        when "Activities::CleanupServicesActivity" then {}
        when "Activities::CleanupWorktreeActivity" then {}
        when "Activities::EnqueueJanitorActivity" then { agent_run_id: 42 }
        else {}
        end
      end
    end

    it "enqueues the janitor activity in the ensure block" do
      stub_successful_run

      workflow.execute(input)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::EnqueueJanitorActivity,
              { agent_run_id: 42 },
              start_to_close_timeout: 10,
              retry_policy: an_instance_of(Temporalio::RetryPolicy))
    end

    it "invokes cleanup activities with CLEANUP_RETRY_POLICY and schedule_to_close_timeout" do
      stub_successful_run

      workflow.execute(input)

      [
        Activities::CleanupContainerActivity,
        Activities::CleanupServicesActivity,
        Activities::CleanupWorktreeActivity
      ].each do |activity_class|
        expect(workflow).to have_received(:run_activity)
          .with(activity_class, { agent_run_id: 42 },
                start_to_close_timeout: 120, schedule_to_close_timeout: 300,
                retry_policy: described_class::CLEANUP_RETRY_POLICY)
      end
    end

    it "does not enqueue janitor when agent_run_id is nil" do
      janitor_calls = []
      allow(workflow).to receive(:run_activity) do |activity_class, input, **opts|
        case activity_class.name
        when "Activities::CreateAgentRunActivity" then { agent_run_id: nil }
        when "Activities::RunAgentActivity"
          raise Temporalio::Error::ApplicationError.new("failed", type: "AgentExecutionFailed")
        when "Activities::MarkAgentRunFailedActivity" then {}
        else
          janitor_calls << { class: activity_class, input: input, opts: opts }
          {}
        end
      end

      expect { workflow.execute(input) }.to raise_error(Temporalio::Error::ApplicationError)

      janitor_enqueued = janitor_calls.any? { |c| c[:class] == Activities::EnqueueJanitorActivity }
      expect(janitor_enqueued).to be false
    end

    it "skips cleanup activities when agent_run_id is nil" do
      called_activities = []
      allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
        called_activities << activity_class
        case activity_class.name
        when "Activities::CreateAgentRunActivity" then { agent_run_id: nil }
        when "Activities::RunAgentActivity"
          raise Temporalio::Error::ApplicationError.new("failed", type: "AgentExecutionFailed")
        else {}
        end
      end

      expect { workflow.execute(input) }.to raise_error(Temporalio::Error::ApplicationError)

      skipped = [ Activities::CleanupContainerActivity, Activities::CleanupServicesActivity,
                  Activities::CleanupWorktreeActivity, Activities::EnqueueJanitorActivity ]
      expect(called_activities & skipped).to be_empty
    end
  end

  describe "container retention for unknown post-agent failures" do
    let(:input) { { project_id: 1, issue_id: 1 } }

    before do
      allow(Rails.application.config.x).to receive(:agent_timeout).and_return(3600)
      allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger, patched: true)
    end

    def stub_post_agent_failure(called_activities, retain_error: nil, retain_result: { agent_run_id: 42, retained: true })
      allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
        called_activities << activity_class
        case activity_class.name
        when "Activities::CreateAgentRunActivity" then { agent_run_id: 42 }
        when "Activities::RunAgentActivity" then { success: true, has_changes: true }
        when "Activities::PushBranchActivity"
          raise Temporalio::Error::ApplicationError.new("Push failed", type: "PushError")
        when "Activities::MarkAgentRunFailedActivity" then {}
        when "Activities::RetainContainerActivity"
          raise retain_error if retain_error
          retain_result
        when "Activities::CleanupContainerActivity" then {}
        when "Activities::CleanupServicesActivity" then {}
        when "Activities::CleanupWorktreeActivity" then {}
        when "Activities::EnqueueJanitorActivity" then {}
        else {}
        end
      end
    end

    it "retains the container when agent succeeded but post-agent step fails" do
      called_activities = []
      stub_post_agent_failure(called_activities)

      expect { workflow.execute(input) }.to raise_error(Temporalio::Error::ApplicationError)

      expect(called_activities).to include(Activities::RetainContainerActivity)
      expect(called_activities).not_to include(Activities::CleanupContainerActivity)
    end

    it "cleans up normally when agent step fails (known failure)" do
      called_activities = []
      allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
        called_activities << activity_class
        case activity_class.name
        when "Activities::CreateAgentRunActivity" then { agent_run_id: 42 }
        when "Activities::RunAgentActivity"
          raise Temporalio::Error::ApplicationError.new(
            "All providers exhausted", type: "AllProvidersExhausted", non_retryable: true
          )
        when "Activities::MarkAgentRunFailedActivity" then {}
        when "Activities::CleanupContainerActivity" then {}
        when "Activities::CleanupServicesActivity" then {}
        when "Activities::CleanupWorktreeActivity" then {}
        when "Activities::EnqueueJanitorActivity" then {}
        else {}
        end
      end

      expect { workflow.execute(input) }.to raise_error(Temporalio::Error::ApplicationError)

      expect(called_activities).to include(Activities::CleanupContainerActivity)
      expect(called_activities).not_to include(Activities::RetainContainerActivity)
    end

    it "cleans up normally on success (no workflow error)" do
      called_activities = []
      allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
        called_activities << activity_class
        case activity_class.name
        when "Activities::CreateAgentRunActivity" then { agent_run_id: 42 }
        when "Activities::RunAgentActivity" then { success: true, has_changes: false }
        when "Activities::MarkAgentRunCompleteActivity" then {}
        when "Activities::CleanupContainerActivity" then {}
        when "Activities::CleanupServicesActivity" then {}
        when "Activities::CleanupWorktreeActivity" then {}
        when "Activities::EnqueueJanitorActivity" then {}
        else {}
        end
      end

      workflow.execute(input)

      expect(called_activities).to include(Activities::CleanupContainerActivity)
      expect(called_activities).not_to include(Activities::RetainContainerActivity)
    end

    it "short-circuits when the run is paused by a guardrail" do
      called_activities = []
      allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
        called_activities << activity_class
        case activity_class.name
        when "Activities::CreateAgentRunActivity" then { agent_run_id: 42 }
        when "Activities::RunAgentActivity" then { success: false, paused: true, agent_run_id: 42 }
        when "Activities::CleanupContainerActivity" then {}
        when "Activities::CleanupServicesActivity" then {}
        when "Activities::CleanupWorktreeActivity" then {}
        when "Activities::EnqueueJanitorActivity" then {}
        else {}
        end
      end

      result = workflow.execute(input)

      expect(result).to include(success: false, paused: true, agent_run_id: 42)
      expect(called_activities).not_to include(Activities::MarkAgentRunCompleteActivity)
      expect(called_activities).not_to include(Activities::MarkAgentRunFailedActivity)
    end

    it "falls back to cleanup when RetainContainerActivity fails" do
      called_activities = []
      stub_post_agent_failure(called_activities, retain_error: StandardError.new("DB write failed"))

      expect { workflow.execute(input) }.to raise_error(Temporalio::Error::ApplicationError)

      expect(called_activities).to include(Activities::RetainContainerActivity)
      expect(called_activities).to include(Activities::CleanupContainerActivity)
    end

    it "falls back to cleanup when RetainContainerActivity returns retained: false" do
      called_activities = []
      stub_post_agent_failure(called_activities, retain_result: { agent_run_id: 42, retained: false })

      expect { workflow.execute(input) }.to raise_error(Temporalio::Error::ApplicationError)

      expect(called_activities).to include(Activities::RetainContainerActivity)
      expect(called_activities).to include(Activities::CleanupContainerActivity)
    end
  end

  describe "PROXY_HEALTH_RETRY_POLICY" do
    it "uses CheckProxyHealthActivity constants for backoff" do
      policy = described_class::PROXY_HEALTH_RETRY_POLICY
      expect(policy).to be_a(Temporalio::RetryPolicy)
      expect(policy.initial_interval).to eq(Activities::CheckProxyHealthActivity::INITIAL_POLL_INTERVAL)
      expect(policy.max_interval).to eq(Activities::CheckProxyHealthActivity::MAX_POLL_INTERVAL)
      expect(policy.backoff_coefficient).to eq(Activities::CheckProxyHealthActivity::BACKOFF_MULTIPLIER)
      expect(policy.max_attempts).to eq(0)
    end
  end

  describe "PROXY_HEALTH_TIMEOUT" do
    it "equals CheckProxyHealthActivity::MAX_WAIT_SECONDS" do
      expect(described_class::PROXY_HEALTH_TIMEOUT).to eq(
        Activities::CheckProxyHealthActivity::MAX_WAIT_SECONDS
      )
    end
  end

  describe "proxy health check before clone" do
    let(:input) { { project_id: 1, issue_id: 1, goal: "create_pr" } }

    before do
      allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger, patched: true)
    end

    it "invokes CheckProxyHealthActivity before CloneRepoActivity" do
      call_order = []
      allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
        call_order << activity_class.name
        case activity_class.name
        when "Activities::CreateAgentRunActivity" then { agent_run_id: 42 }
        when "Activities::RunAgentActivity" then { success: true, has_changes: false }
        when "Activities::MarkAgentRunCompleteActivity" then {}
        else {}
        end
      end

      workflow.execute(input)

      health_idx = call_order.index("Activities::CheckProxyHealthActivity")
      clone_idx = call_order.index("Activities::CloneRepoActivity")
      expect(health_idx).not_to be_nil
      expect(clone_idx).not_to be_nil
      expect(health_idx).to be < clone_idx
    end

    it "passes expected timeout and retry options to CheckProxyHealthActivity" do
      allow(workflow).to receive(:run_activity) do |activity_class, _input, **opts|
        case activity_class.name
        when "Activities::CreateAgentRunActivity" then { agent_run_id: 42 }
        when "Activities::CheckProxyHealthActivity"
          expect(opts[:start_to_close_timeout]).to eq(30)
          expect(opts[:schedule_to_close_timeout]).to eq(described_class::PROXY_HEALTH_TIMEOUT)
          expect(opts[:retry_policy]).to eq(described_class::PROXY_HEALTH_RETRY_POLICY)
          { healthy: true }
        when "Activities::RunAgentActivity" then { success: true, has_changes: false }
        when "Activities::MarkAgentRunCompleteActivity" then {}
        else {}
        end
      end

      workflow.execute(input)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::CheckProxyHealthActivity, { agent_run_id: 42 },
              start_to_close_timeout: 30,
              schedule_to_close_timeout: described_class::PROXY_HEALTH_TIMEOUT,
              retry_policy: described_class::PROXY_HEALTH_RETRY_POLICY)
    end

    it "skips health check for create_issue goal without source PR" do
      issue_input = { project_id: 1, issue_id: 1, goal: "create_issue" }
      allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
        case activity_class.name
        when "Activities::CreateAgentRunActivity" then { agent_run_id: 42 }
        when "Activities::RunAgentActivity" then { success: true }
        when "Activities::CompleteIssueGoalActivity" then { issue_created: true }
        else {}
        end
      end

      workflow.execute(issue_input)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::CheckProxyHealthActivity, anything, any_args)
    end
  end

  describe "proxy health check before push" do
    let(:input) { { project_id: 1, issue_id: 1, goal: "create_pr" } }

    before do
      allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger, patched: true)
    end

    it "invokes CheckProxyHealthActivity before PushBranchActivity" do
      call_order = []
      allow(workflow).to receive(:run_activity) do |activity_class, _input, **_opts|
        call_order << activity_class.name
        case activity_class.name
        when "Activities::CreateAgentRunActivity" then { agent_run_id: 42 }
        when "Activities::RunAgentActivity" then { success: true, has_changes: true }
        when "Activities::CreatePullRequestActivity"
          { pull_request_url: "https://github.com/o/r/pull/1", pull_request_number: 1 }
        else {}
        end
      end

      workflow.execute(input)

      # There should be two health checks — one before clone, one before push
      health_indices = call_order.each_index.select { |i| call_order[i] == "Activities::CheckProxyHealthActivity" }
      push_idx = call_order.index("Activities::PushBranchActivity")
      expect(health_indices.length).to eq(2)
      expect(push_idx).not_to be_nil
      expect(health_indices.last).to be < push_idx
    end
  end

  describe "#ensure_proxy_healthy timeout conversion" do
    let(:workflow) { described_class.new }

    before do
      allow(Temporalio::Workflow).to receive(:logger).and_return(Rails.logger)
    end

    def timeout_activity_error
      timeout_error = Temporalio::Error::TimeoutError.new(
        "schedule to close timeout",
        type: Temporalio::Error::TimeoutError::TimeoutType::SCHEDULE_TO_CLOSE,
        last_heartbeat_details: []
      )
      activity_error_wrapping(timeout_error, retry_state: Temporalio::Error::RetryState::TIMEOUT)
    end

    def config_activity_error
      app_error = Temporalio::Error::ApplicationError.new(
        "config error", type: "ProxyConfigurationError", non_retryable: true
      )
      activity_error_wrapping(app_error)
    end

    def activity_error_wrapping(cause, retry_state: Temporalio::Error::RetryState::NON_RETRYABLE_FAILURE)
      begin
        begin
          raise cause
        rescue
          raise Temporalio::Error::ActivityError.new(
            "activity failed",
            scheduled_event_id: 1, started_event_id: 2, identity: "",
            activity_type: "CheckProxyHealth", activity_id: "1",
            retry_state: retry_state
          )
        end
      rescue => e
        e
      end
    end

    it "converts Temporal TimeoutError to non-retryable ProxyUnavailable" do
      allow(workflow).to receive(:run_activity).and_raise(timeout_activity_error)

      expect {
        workflow.send(:ensure_proxy_healthy, 42)
      }.to raise_error(Temporalio::Error::ApplicationError) { |error|
        expect(error.type).to eq("ProxyUnavailable")
        expect(error.non_retryable).to be true
        expect(error.message).to include(described_class::PROXY_HEALTH_TIMEOUT.to_s)
      }
    end

    it "re-raises non-timeout ActivityErrors" do
      allow(workflow).to receive(:run_activity).and_raise(config_activity_error)

      expect {
        workflow.send(:ensure_proxy_healthy, 42)
      }.to raise_error(Temporalio::Error::ActivityError)
    end
  end

  describe "ProxyUnavailable as known failure" do
    it "includes ProxyUnavailable in KNOWN_FAILURE_TYPES" do
      expect(described_class::KNOWN_FAILURE_TYPES).to include("ProxyUnavailable")
    end

    it "does not retain container for ProxyUnavailable failure" do
      cause = Temporalio::Error::ApplicationError.new(
        "proxy unavailable", type: "ProxyUnavailable", non_retryable: true
      )
      error = begin
        begin
          raise cause
        rescue
          raise Temporalio::Error::ActivityError.new(
            "activity failed",
            scheduled_event_id: 1, started_event_id: 2, identity: "",
            activity_type: "CheckProxyHealth", activity_id: "1",
            retry_state: Temporalio::Error::RetryState::NON_RETRYABLE_FAILURE
          )
        end
      rescue => e
        e
      end

      expect(workflow.send(:should_retain_container?, true, error)).to be false
    end
  end

  describe "#should_retain_container?" do
    let(:workflow) { described_class.new }

    def activity_error_with_cause(cause)
      activity_err = Temporalio::Error::ActivityError.new(
        "activity failed",
        scheduled_event_id: 1,
        started_event_id: 2,
        identity: "",
        activity_type: "PushBranch",
        activity_id: "1",
        retry_state: Temporalio::Error::RetryState::NON_RETRYABLE_FAILURE
      )
      begin
        begin
          raise cause
        rescue
          raise activity_err
        end
      rescue => e
        e
      end
    end

    it "returns true when agent succeeded and error is unknown" do
      cause = Temporalio::Error::ApplicationError.new("Push failed", type: "PushError")
      error = activity_error_with_cause(cause)

      expect(workflow.send(:should_retain_container?, true, error)).to be true
    end

    it "returns false when agent did not succeed" do
      error = RuntimeError.new("something")

      expect(workflow.send(:should_retain_container?, false, error)).to be false
    end

    it "returns false when there is no workflow error" do
      expect(workflow.send(:should_retain_container?, true, nil)).to be false
    end

    it "returns false for CanceledError" do
      error = Temporalio::Error::CanceledError.new("cancelled")

      expect(workflow.send(:should_retain_container?, true, error)).to be false
    end

    it "returns false for known failure types" do
      described_class::KNOWN_FAILURE_TYPES.each do |type|
        cause = Temporalio::Error::ApplicationError.new("error", type: type)
        error = activity_error_with_cause(cause)

        expect(workflow.send(:should_retain_container?, true, error)).to be(false),
          "Expected false for known failure type #{type}"
      end
    end

    it "returns false for known failure types nested deeper in the cause chain" do
      # ActivityError -> RuntimeError(wrapper) -> ApplicationError(known type)
      # The known type is two levels deep in the cause chain from the ActivityError.
      app_error = Temporalio::Error::ApplicationError.new("exhausted", type: "AllProvidersExhausted")

      wrapper =
        begin
          begin
            raise app_error
          rescue
            raise RuntimeError, "wrapper"
          end
        rescue => e
          e
        end

      error = activity_error_with_cause(wrapper)

      expect(workflow.send(:should_retain_container?, true, error)).to be false
    end

    it "returns false for CanceledError wrapped in ActivityError" do
      cause = Temporalio::Error::CanceledError.new("cancelled")
      error = activity_error_with_cause(cause)

      expect(workflow.send(:should_retain_container?, true, error)).to be false
    end

    it "returns false for GithubClient::RateLimitError" do
      error = GithubClient::RateLimitError.new(Time.current + 3600)

      expect(workflow.send(:should_retain_container?, true, error)).to be false
    end

    it "returns false for GithubClient::AuthenticationError" do
      error = GithubClient::AuthenticationError.new("token expired")

      expect(workflow.send(:should_retain_container?, true, error)).to be false
    end

    it "returns false for GithubClient::RateLimitError wrapped as ApplicationError" do
      cause = Temporalio::Error::ApplicationError.new("rate limited", type: "GithubClient::RateLimitError")
      error = activity_error_with_cause(cause)

      expect(workflow.send(:should_retain_container?, true, error)).to be false
    end

    it "returns false for GithubClient::AuthenticationError wrapped as ApplicationError" do
      cause = Temporalio::Error::ApplicationError.new("token expired", type: "GithubClient::AuthenticationError")
      error = activity_error_with_cause(cause)

      expect(workflow.send(:should_retain_container?, true, error)).to be false
    end
  end

  describe "#unwrap_error_message" do
    let(:workflow) { described_class.new }

    def activity_error_with_cause(cause)
      activity_err = Temporalio::Error::ActivityError.new(
        "activity failed",
        scheduled_event_id: 1,
        started_event_id: 2,
        identity: "",
        activity_type: "PushBranch",
        activity_id: "1",
        retry_state: Temporalio::Error::RetryState::NON_RETRYABLE_FAILURE
      )
      begin
        begin
          raise cause
        rescue
          raise activity_err
        end
      rescue => e
        e
      end
    end

    it "extracts ApplicationError message from wrapped ActivityError" do
      cause = Temporalio::Error::ApplicationError.new("Push failed: rejected by remote", type: "PushError")
      error = activity_error_with_cause(cause)

      expect(workflow.send(:unwrap_error_message, error)).to eq("Push failed: rejected by remote")
    end

    it "returns the error message directly when no ApplicationError cause" do
      error = RuntimeError.new("something went wrong")

      expect(workflow.send(:unwrap_error_message, error)).to eq("something went wrong")
    end

    it "returns the error message when cause is not an ApplicationError" do
      outer = StandardError.new("outer error")
      begin
        begin
          raise RuntimeError, "inner error"
        rescue
          raise outer
        end
      rescue => e
        expect(workflow.send(:unwrap_error_message, e)).to eq("outer error")
      end
    end
  end

  describe "#stale_pull_request_error?" do
    let(:workflow) { described_class.new }

    def activity_error_with_cause(cause)
      activity_err = Temporalio::Error::ActivityError.new(
        "activity failed",
        scheduled_event_id: 1,
        started_event_id: 2,
        identity: "",
        activity_type: "CloneRepo",
        activity_id: "1",
        retry_state: Temporalio::Error::RetryState::NON_RETRYABLE_FAILURE
      )
      # Use Ruby's raise/rescue to set the real cause
      begin
        begin
          raise cause
        rescue
          raise activity_err
        end
      rescue => e
        e
      end
    end

    it "returns true for ActivityError wrapping StalePullRequest ApplicationError" do
      cause = Temporalio::Error::ApplicationError.new("stale", type: "StalePullRequest")
      error = activity_error_with_cause(cause)

      expect(workflow.send(:stale_pull_request_error?, error)).to be true
    end

    it "returns false for other ApplicationError types" do
      cause = Temporalio::Error::ApplicationError.new("conflict", type: "WorktreeConflict")
      error = activity_error_with_cause(cause)

      expect(workflow.send(:stale_pull_request_error?, error)).to be false
    end

    it "returns false for errors without a cause" do
      error = RuntimeError.new("something went wrong")
      expect(workflow.send(:stale_pull_request_error?, error)).to be false
    end
  end
end
