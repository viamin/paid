# frozen_string_literal: true

# Regenerates the pre-#5288 ("legacy") AgentExecutionWorkflow replay-history
# fixtures used to prove that the evidence-backed follow-up review-resolution
# change (#5288) stays replay-compatible with histories recorded BEFORE it.
#
# These histories are SYNTHETIC (driven through a time-skipping
# `Temporalio::Testing::WorkflowEnvironment` with the stub activities below),
# but they are legitimate WorkflowReplayer input: they record the OLD command
# sequence — ResolveReviewThreads scheduled in its original position — because
# the `evidence-backed-followup-review-resolution-v1` patch is forced OFF
# during generation. Replaying them against current code (which calls the real
# `patched`, returning false for a markerless history) must reproduce exactly
# that sequence, which is what `workflow_replay_fixtures_spec.rb` asserts.
#
# A handful of control-routing guards are also forced off so every activity
# stays on the single agent task queue the generator worker serves. On replay
# the real `patched` likewise returns false for those markerless guards, so the
# routing matches.
#
# Re-run after changing the no-change / changed-head existing-PR command shape:
#
#     bin/rails runner script/temporal/export_review_followup_histories.rb
#
# and commit the regenerated JSON alongside the workflow change.

ENV["RAILS_ENV"] ||= "test"
ENV["PAID_SKIP_DATABASE_RUNTIME_ROLE_GUARD"] = "true"

require_relative "../../config/environment"
require "fileutils"
require "temporalio/testing"
require "temporalio/worker"
require "temporalio/activity/definition"
require "paid/temporal_data_converter"

Rails.application.eager_load!

module Script
  module Temporal
    class ExportReviewFollowupHistories
      FIXTURE_DIR = Rails.root.join("spec/fixtures/temporal/review_followup_replay_histories")
      TASK_QUEUE = Paid::AGENT_TASK_QUEUE

      # Guards forced off during generation so the recorded history matches a
      # pre-#5288 execution and keeps every activity on the agent queue.
      FORCED_LEGACY_PATCHES = %w[
        evidence-backed-followup-review-resolution-v1
        proxy-health-control-routing-v1
        cleanup-owned-resources-v1
        enqueue-janitor-control-routing-v1
      ].freeze

      SCENARIOS = {
        # Existing-PR follow-up where the agent reports the feedback already
        # addressed but pushes no code. The old path resolved the captured
        # thread BEFORE MarkAgentRunComplete.
        "agent_execution_legacy_no_change_review_followup" =>
          { input: { project_id: 1, issue_id: 1, source_pull_request_number: 42, goal: "create_pr" }, has_changes: false },
        # Existing-PR follow-up where the agent pushes a changed head. The old
        # path resolved the captured thread right after PushBranch.
        "agent_execution_legacy_changed_head_review_followup" =>
          { input: { project_id: 1, issue_id: 1, source_pull_request_number: 42, goal: "create_pr" }, has_changes: true }
      }.freeze

      ACTIVITY_RETURNS = {
        "CreateAgentRunActivity" => { agent_run_id: 42, runner_attempt_count: 1, agent_timeout_seconds: 300, issue_goal_timeout_seconds: 60, focus: "general" },
        "CheckQualityGateActivity" => { allowed: true },
        "ProvisionServicesActivity" => {},
        "ProvisionMcpServersActivity" => {},
        "ProvisionBrowserContainerActivity" => { status: "skipped" },
        "ProvisionContainerActivity" => {},
        "CheckProxyHealthActivity" => {},
        "CloneRepoActivity" => {},
        "RebaseBranchActivity" => { rebase_succeeded: true, branch_changed: false },
        "PreparePrPromptActivity" => { includes_review_threads: true, review_thread_ids: [ "thread_1" ] },
        "PushBranchActivity" => {},
        "ResolveReviewThreadsActivity" => {},
        "CompleteExistingPrRunActivity" => { pr_review_phase: "ready" },
        "MarkAgentRunCompleteActivity" => {},
        "RequestReviewActivity" => {},
        "DraftDecisionRecordActivity" => {},
        "CleanupContainerActivity" => {},
        "CleanupMcpServersActivity" => {},
        "CleanupServicesActivity" => {},
        "CleanupWorktreeActivity" => {},
        "EnqueueJanitorActivity" => {}
      }.freeze

      def self.call
        new.call
      end

      def call
        force_legacy_patches!
        FileUtils.mkdir_p(FIXTURE_DIR)

        Temporalio::Testing::WorkflowEnvironment.start_time_skipping(data_converter: Paid::TemporalDataConverter.new) do |environment|
          worker = Temporalio::Worker.new(
            client: environment.client,
            task_queue: TASK_QUEUE,
            activities: activity_definitions,
            workflows: [ Workflows::AgentExecutionWorkflow ],
            workflow_failure_exception_types: [ Exception ]
          )

          worker_thread = Thread.new { worker.run }
          begin
            SCENARIOS.each { |name, scenario| export(environment, name, scenario) }
          ensure
            worker_thread&.kill
            worker_thread&.join
          end
        end
      end

      private

      def force_legacy_patches!
        forced = FORCED_LEGACY_PATCHES
        Temporalio::Workflow.singleton_class.prepend(Module.new do
          define_method(:patched) do |patch_id|
            next false if forced.include?(patch_id.to_s)

            super(patch_id)
          end
        end)
      end

      def export(environment, name, scenario)
        @has_changes = scenario[:has_changes]
        handle = environment.client.start_workflow(
          Workflows::AgentExecutionWorkflow, scenario[:input],
          id: "replay-history-#{name}", task_queue: TASK_QUEUE
        )
        handle.result
        FIXTURE_DIR.join("#{name}.json").write(handle.fetch_history.to_history_json)
      end

      def activity_definitions
        definitions = ACTIVITY_RETURNS.map do |class_name, value|
          build_activity(class_name) { value }
        end
        definitions << build_activity("RunAgentActivity") do
          { success: true, has_changes: @has_changes, review_threads_already_addressed: true }
        end
      end

      def build_activity(class_name)
        Temporalio::Activity::Definition::Info.new(name: activity_name_for(class_name)) do |*args|
          yield(*args)
        end
      end

      def activity_name_for(class_name)
        "Activities::#{class_name}".constantize._activity_definition_details.fetch(:activity_name)
      end
    end
  end
end

Script::Temporal::ExportReviewFollowupHistories.call
