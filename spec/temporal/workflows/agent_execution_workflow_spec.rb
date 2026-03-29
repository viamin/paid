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
      allow(Temporalio::Workflow).to receive(:logger).and_return(Rails.logger)
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
      allow(Temporalio::Workflow).to receive(:logger).and_return(Rails.logger)
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
      allow(Temporalio::Workflow).to receive(:logger).and_return(Rails.logger)
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
      allow(Temporalio::Workflow).to receive(:logger).and_return(Rails.logger)
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
      allow(Temporalio::Workflow).to receive(:logger).and_return(Rails.logger)
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

  describe "existing PR follow-up reviews" do
    let(:input) { { project_id: 1, issue_id: 1, source_pull_request_number: 42 } }

    before do
      allow(Rails.application.config.x).to receive(:agent_timeout).and_return(3600)
      allow(Temporalio::Workflow).to receive(:logger).and_return(Rails.logger)
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
        when "Activities::RequestReviewActivity" then {}
        when "Activities::CleanupContainerActivity" then {}
        when "Activities::CleanupServicesActivity" then {}
        when "Activities::CleanupWorktreeActivity" then {}
        else {}
        end
      end
    end

    it "re-requests Copilot review after pushing commits to a ready PR" do
      stub_existing_pr_followup(pr_review_phase: "ready")

      workflow.execute(input)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity,
          { project_id: 1, pr_number: 42,
            reviewers: [ Activities::RequestReviewActivity::COPILOT_LOGIN ] },
          timeout: 60)
    end

    it "does not request Copilot review after pushing commits to a merged PR" do
      stub_existing_pr_followup(pr_review_phase: "merged")

      workflow.execute(input)

      expect(workflow).not_to have_received(:run_activity)
        .with(Activities::RequestReviewActivity, any_args)
    end
  end

  describe "existing PR follow-up with no changes" do
    let(:input) { { project_id: 1, issue_id: 1, source_pull_request_number: 42 } }

    before do
      allow(Rails.application.config.x).to receive(:agent_timeout).and_return(3600)
      allow(Temporalio::Workflow).to receive(:logger).and_return(Rails.logger)
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
        when "Activities::RequestReviewActivity" then {}
        when "Activities::CleanupContainerActivity" then {}
        when "Activities::CleanupServicesActivity" then {}
        when "Activities::CleanupWorktreeActivity" then {}
        else {}
        end
      end
    end

    it "requests Copilot review even when agent makes no changes on existing PR" do
      stub_no_changes_followup

      workflow.execute(input)

      expect(workflow).to have_received(:run_activity)
        .with(Activities::RequestReviewActivity,
          { project_id: 1, pr_number: 42,
            reviewers: [ Activities::RequestReviewActivity::COPILOT_LOGIN ] },
          timeout: 60)
    end
  end

  describe "ensure block cleanup and janitor enqueue" do
    let(:input) { { project_id: 1, issue_id: 1 } }

    before do
      allow(Rails.application.config.x).to receive(:agent_timeout).and_return(3600)
      allow(Temporalio::Workflow).to receive(:logger).and_return(Rails.logger)
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
      allow(Temporalio::Workflow).to receive(:logger).and_return(Rails.logger)
    end

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

    def stub_post_agent_failure(called_activities, retain_error: nil)
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
          { agent_run_id: 42, retained: true }
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

    it "falls back to cleanup when RetainContainerActivity fails" do
      called_activities = []
      stub_post_agent_failure(called_activities, retain_error: StandardError.new("DB write failed"))

      expect { workflow.execute(input) }.to raise_error(Temporalio::Error::ApplicationError)

      expect(called_activities).to include(Activities::RetainContainerActivity)
      expect(called_activities).to include(Activities::CleanupContainerActivity)
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
