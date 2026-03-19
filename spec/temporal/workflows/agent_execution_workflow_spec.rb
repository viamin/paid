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
        when "Activities::CreateAgentRunActivity" then { agent_run_id: 42, provider_attempt_count: 3 }
        when "Activities::RunAgentActivity"
          expected_timeout = (Activities::RunAgentActivity::ISSUE_GOAL_TIMEOUT * 3) + 300
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
