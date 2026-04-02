# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::ParallelAgentExecutionWorkflow do
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

  describe "constants" do
    it "defines DEFAULT_TIMEOUT_SECONDS" do
      expect(described_class::DEFAULT_TIMEOUT_SECONDS).to eq(7200)
    end

    it "defines MAX_SUB_TASKS" do
      expect(described_class::MAX_SUB_TASKS).to eq(20)
    end

    it "does not define PROGRESS_POLL_INTERVAL (unused)" do
      expect(described_class.const_defined?(:PROGRESS_POLL_INTERVAL)).to be false
    end
  end

  describe "input validation" do
    before do
      stub_temporal_workflow
    end

    it "raises InvalidInput when project_id is missing" do
      expect {
        workflow.execute({ sub_tasks: [ { issue_id: 1 } ] })
      }.to raise_error(Temporalio::Error::ApplicationError, "project_id is required") do |error|
        expect(error.type).to eq("InvalidInput")
      end
    end

    it "raises InvalidInput when sub_tasks is empty" do
      expect {
        workflow.execute({ project_id: 1, sub_tasks: [] })
      }.to raise_error(Temporalio::Error::ApplicationError, "sub_tasks must not be empty") do |error|
        expect(error.type).to eq("InvalidInput")
      end
    end

    it "raises InvalidInput when sub_tasks exceeds maximum" do
      sub_tasks = Array.new(21) { |i| { issue_id: i } }

      expect {
        workflow.execute({ project_id: 1, sub_tasks: sub_tasks })
      }.to raise_error(Temporalio::Error::ApplicationError, /exceeds maximum/) do |error|
        expect(error.type).to eq("InvalidInput")
      end
    end

    it "raises InvalidInput when a sub_task is not a Hash" do
      expect {
        workflow.execute({ project_id: 1, sub_tasks: [ "not_a_hash" ] })
      }.to raise_error(Temporalio::Error::ApplicationError, "sub_tasks[0] must be a Hash") do |error|
        expect(error.type).to eq("InvalidInput")
      end
    end

    it "raises InvalidInput when a sub_task lacks both issue_id and custom_prompt" do
      expect {
        workflow.execute({ project_id: 1, sub_tasks: [ { agent_type: "claude_code" } ] })
      }.to raise_error(Temporalio::Error::ApplicationError, /must include at least one of/) do |error|
        expect(error.type).to eq("InvalidInput")
      end
    end

    it "accepts sub_task with only custom_prompt" do
      stub_full_capacity
      stub_successful_futures(count: 1)
      stub_no_conflicts
      allow(Temporalio::Workflow).to receive(:now).and_return(Time.now)

      result = workflow.execute({ project_id: 1, sub_tasks: [ { custom_prompt: "do something" } ] })
      expect(result[:success]).to be true
    end
  end

  describe "capacity check" do
    before { stub_temporal_workflow }

    it "returns no_capacity error when project has no capacity" do
      stub_no_capacity

      input = { project_id: 1, sub_tasks: [ { issue_id: 1 } ] }
      result = workflow.execute(input)

      expect(result[:success]).to be false
      expect(result[:error]).to eq("no_capacity")
    end

    it "propagates specific error from capacity check" do
      stub_no_capacity_with_error("project_not_found")

      input = { project_id: 1, sub_tasks: [ { issue_id: 1 } ] }
      result = workflow.execute(input)

      expect(result[:success]).to be false
      expect(result[:error]).to eq("project_not_found")
    end
  end

  describe "parallel execution" do
    before do
      stub_temporal_workflow
      allow(Temporalio::Workflow).to receive(:now).and_return(Time.now)
    end

    it "launches child workflows and collects results" do
      stub_full_capacity
      stub_successful_futures(count: 2)
      stub_no_conflicts

      result = workflow.execute(two_task_input)

      expect(result[:success]).to be true
      expect(result[:total]).to eq(2)
      expect(result[:completed]).to eq(2)
    end

    it "reports failures from child workflows" do
      stub_full_capacity
      stub_mixed_futures
      stub_no_conflicts

      result = workflow.execute(two_task_input)

      expect(result[:success]).to be false
      expect(result[:completed]).to eq(1)
      expect(result[:failed]).to eq(1)
    end

    it "batches sub-tasks based on available slots" do
      capacity_call_count = stub_incremental_capacity
      stub_successful_futures(count: 3)
      stub_no_conflicts

      result = workflow.execute(three_task_input)

      expect(capacity_call_count.call).to eq(3)
      expect(result[:total]).to eq(3)
    end

    it "marks remaining tasks as no_capacity when capacity runs out" do
      stub_capacity_then_exhausted
      stub_successful_futures(count: 1)
      stub_no_conflicts

      result = workflow.execute(two_task_input)

      expect(result[:total]).to eq(2)
      successful = result[:results].count { |r| r[:success] }
      queued = result[:results].count { |r| r[:queued] }
      expect(successful).to eq(1)
      expect(queued).to eq(1)
    end

    it "respects shrinking available_slots between batches" do
      # First capacity check returns 2 slots, subsequent checks return 1.
      # With 3 tasks: batch 0 gets 2 tasks, batch 1 re-checks and gets 1 slot,
      # so batch 1 should only launch 1 task.
      stub_shrinking_capacity
      stub_successful_futures(count: 3)
      stub_no_conflicts

      result = workflow.execute(three_task_input)

      expect(result[:success]).to be true
      expect(result[:total]).to eq(3)
      expect(result[:completed]).to eq(3)
    end

    it "marks remaining tasks as deadline_exceeded when overall timeout expires" do
      # Capacity returns 1 slot so tasks are batched one at a time
      stub_incremental_capacity
      stub_successful_futures(count: 3)
      stub_no_conflicts

      # Simulate time passing beyond the deadline after first batch completes
      now = Time.now
      call_count = 0
      allow(Temporalio::Workflow).to receive(:now) do
        call_count += 1
        # After several calls (first batch done), jump past the deadline
        call_count > 5 ? now + 100 : now
      end

      result = workflow.execute(
        project_id: 1,
        sub_tasks: [ { issue_id: 10 }, { issue_id: 20 }, { issue_id: 30 } ],
        timeout_seconds: 50
      )

      deadline_exceeded = result[:results].select { |r| r[:error] == "deadline_exceeded" }
      expect(deadline_exceeded).not_to be_empty
    end

    it "includes conflict detection results" do
      stub_full_capacity
      stub_successful_futures(count: 2)
      stub_no_conflicts

      result = workflow.execute(two_task_input)

      expect(result[:conflicts]).to be_a(Hash)
      expect(result[:conflicts][:has_conflicts]).to be false
    end

    it "detects conflicts between successful runs" do
      stub_full_capacity
      stub_successful_futures(count: 2)
      stub_conflict_detected_and_unresolved

      result = workflow.execute(two_task_input)

      expect(result[:conflicts][:has_conflicts]).to be true
      expect(result[:conflicts][:resolution][:requires_manual_review]).to be true
    end
  end

  private

  def stub_temporal_workflow
    workflow_info = Struct.new(:workflow_id).new("test-parallel-wf")
    allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger, info: workflow_info)
  end

  def stub_no_conflicts
    allow(workflow).to receive(:run_activity)
      .with(Activities::DetectConflictsActivity, anything, timeout: 120)
      .and_return(has_conflicts: false, conflicting_pairs: [], files_by_run: {}, total_runs_checked: 0)
  end

  def stub_conflict_detected_and_unresolved
    detection = {
      has_conflicts: true,
      conflicting_pairs: [ { runs: [ 42, 43 ], files: [ "src/app.rb" ] } ],
      files_by_run: { 42 => [ "src/app.rb" ], 43 => [ "src/app.rb" ] }, total_runs_checked: 2
    }
    resolution = {
      resolved: false, strategy: :auto_rebase,
      resolutions: [ { runs: [ 42, 43 ], files: [ "src/app.rb" ], resolved: false, action: :manual } ],
      requires_manual_review: true
    }
    allow(workflow).to receive(:run_activity)
      .with(Activities::DetectConflictsActivity, anything, timeout: 120).and_return(detection)
    allow(workflow).to receive(:run_activity)
      .with(Activities::ResolveConflictsActivity, anything, timeout: 300).and_return(resolution)
  end

  def stub_no_capacity
    allow(workflow).to receive(:run_activity)
      .with(Activities::CheckProjectRunCapacityActivity, anything, timeout: 30)
      .and_return(has_capacity: false, available_slots: 0, project_active_count: 3, max_parallel_per_project: 3)
  end

  def stub_no_capacity_with_error(error)
    allow(workflow).to receive(:run_activity)
      .with(Activities::CheckProjectRunCapacityActivity, anything, timeout: 30)
      .and_return(has_capacity: false, available_slots: 0, error: error)
  end

  def full_capacity_result
    {
      has_capacity: true, available_slots: 5, project_active_count: 0,
      max_parallel_per_project: 5, user_active_count: 0, max_concurrent_runs: 10
    }
  end

  def stub_full_capacity
    allow(workflow).to receive(:run_activity)
      .with(Activities::CheckProjectRunCapacityActivity, anything, timeout: 30)
      .and_return(full_capacity_result)
  end

  def stub_successful_futures(count:)
    future = Struct.new(:done?, :failure?, :failure, :result, keyword_init: true)
      .new("done?": true, "failure?": false, failure: nil, result: { success: true, agent_run_id: 42 })

    all_done = Struct.new(:wait).new(nil)
    allow(Temporalio::Workflow::Future).to receive_messages(new: future, try_all_of: all_done)
  end

  def stub_mixed_futures
    success = Struct.new(:done?, :failure?, :failure, :result, keyword_init: true)
      .new("done?": true, "failure?": false, failure: nil, result: { success: true, agent_run_id: 42 })
    error = StandardError.new("Agent execution failed")
    failure = Struct.new(:done?, :failure?, :failure, :result, keyword_init: true)
      .new("done?": true, "failure?": true, failure: error, result: nil)

    index = 0
    allow(Temporalio::Workflow::Future).to receive(:new) do
      index += 1
      index == 1 ? success : failure
    end

    all_done = Struct.new(:wait).new(nil)
    allow(Temporalio::Workflow::Future).to receive(:try_all_of).and_return(all_done)
  end

  def stub_incremental_capacity
    call_count = 0
    allow(workflow).to receive(:run_activity)
      .with(Activities::CheckProjectRunCapacityActivity, anything, timeout: 30) do
        call_count += 1
        {
          has_capacity: true, available_slots: 1,
          project_active_count: call_count - 1, max_parallel_per_project: 3,
          user_active_count: call_count - 1, max_concurrent_runs: 10
        }
      end

    -> { call_count }
  end

  def stub_shrinking_capacity
    call_count = 0
    allow(workflow).to receive(:run_activity)
      .with(Activities::CheckProjectRunCapacityActivity, anything, timeout: 30) do
        call_count += 1
        if call_count == 1
          full_capacity_result.merge(available_slots: 2)
        else
          { has_capacity: true, available_slots: 1,
            project_active_count: 2, max_parallel_per_project: 3,
            user_active_count: 2, max_concurrent_runs: 10 }
        end
      end
  end

  def stub_capacity_then_exhausted
    call_count = 0
    allow(workflow).to receive(:run_activity)
      .with(Activities::CheckProjectRunCapacityActivity, anything, timeout: 30) do
        call_count += 1
        if call_count == 1
          full_capacity_result.merge(available_slots: 1)
        else
          { has_capacity: false, available_slots: 0, project_active_count: 3,
            max_parallel_per_project: 3, user_active_count: 3, max_concurrent_runs: 10 }
        end
      end
  end

  def two_task_input
    { project_id: 1, sub_tasks: [ { issue_id: 10 }, { issue_id: 20 } ] }
  end

  def three_task_input
    { project_id: 1, sub_tasks: [ { issue_id: 10 }, { issue_id: 20 }, { issue_id: 30 } ] }
  end
end
