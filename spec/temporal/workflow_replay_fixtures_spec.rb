# frozen_string_literal: true

require "rails_helper"
require "json"
require "temporalio/worker"
require "temporalio/worker/workflow_replayer"
require "temporalio/workflow_history"
require "temporalio/testing"

Rails.application.eager_load!

RSpec.describe WorkflowReplayFixtures, :no_db do
  let(:fixture_dir) { Rails.root.join("spec/fixtures/temporal/replay_histories") }

  it "has a saved history fixture for every workflow" do
    fixture_names = Dir.glob(fixture_dir.join("*.json")).map { |path| File.basename(path, ".json") }.sort
    workflow_names = described_class.workflow_classes.map { |klass| klass.name.demodulize.underscore }.sort

    expect(fixture_names).to eq(workflow_names)
  end

  it "uses checked-in replay inputs for every workflow" do
    described_class.workflow_classes.each do |workflow_class|
      expect(described_class.scenario_for(workflow_class).input).to be_present
    end
  end

  it "stores representative histories instead of failure-only boot traces" do
    representative_event_types = %w[
      EVENT_TYPE_ACTIVITY_TASK_SCHEDULED
      EVENT_TYPE_CHILD_WORKFLOW_EXECUTION_STARTED
      EVENT_TYPE_TIMER_STARTED
    ]

    described_class.workflow_classes.each do |workflow_class|
      history = JSON.parse(fixture_dir.join("#{workflow_class.name.demodulize.underscore}.json").read)
      event_types = history.fetch("events").map { |event| event.fetch("eventType") }

      expect(event_types & representative_event_types).not_to be_empty
    end
  end

  # Captured from the unpatched production workflow with synthetic activities.
  # @spec TEMPORAL-ORCHESTRATION-015
  it "replays legacy acceptance-audit failure publication on its original queue" do
    history = Temporalio::WorkflowHistory.from_history_json(
      Rails.root.join("spec/fixtures/temporal/agent_execution_failure_history.json").read
    )
    publication = history.events.filter_map(&:activity_task_scheduled_event_attributes)
      .find { |activity| activity.activity_type.name == "MarkAgentRunFailed" }
    expect(publication.task_queue.name).to eq("paid-agent-tasks")
    expect(publication.start_to_close_timeout.seconds).to eq(30)
    expect(publication.retry_policy.maximum_attempts).to eq(3)

    cleanup_activity_names = history.events.filter_map(&:activity_task_scheduled_event_attributes)
      .map { |activity| activity.activity_type.name }
    expect(cleanup_activity_names).to include(
      "CleanupContainer", "CleanupMcpServers", "CleanupServices", "CleanupWorktree", "EnqueueJanitor"
    )

    result = Temporalio::Worker::WorkflowReplayer.new(
      workflows: [ Workflows::AgentExecutionWorkflow ],
      data_converter: Paid::TemporalDataConverter.new,
      logger: Logger.new(nil),
      workflow_failure_exception_types: [ Exception ]
    ).replay_workflow(history, raise_on_replay_failure: false)

    expect(result.replay_failure).to be_nil
  end

  described_class.workflow_classes.each do |workflow_class|
    it "replays #{workflow_class.name.demodulize} from its saved history" do
      history = Temporalio::WorkflowHistory.from_history_json(
        fixture_dir.join("#{workflow_class.name.demodulize.underscore}.json").read
      )

      result = Temporalio::Worker::WorkflowReplayer.new(
        workflows: [ workflow_class ],
        data_converter: Paid::TemporalDataConverter.new,
        logger: Logger.new(nil),
        workflow_failure_exception_types: [ Exception ]
      ).replay_workflow(history, raise_on_replay_failure: false)

      expect(result.replay_failure).to be_nil
    end
  end

  describe "evolution workflow codec compatibility" do
    let(:evolution_workflows) do
      [ Workflows::CoordinationPolicyEvolutionWorkflow, Workflows::PromptEvolutionWorkflow ].freeze
    end

    def evolution_replay(workflow_class, data_converter: nil)
      history = Temporalio::WorkflowHistory.from_history_json(
        fixture_dir.join("#{workflow_class.name.demodulize.underscore}.json").read
      )
      options = { workflows: [ workflow_class ], logger: Logger.new(nil), workflow_failure_exception_types: [ Exception ] }
      options[:data_converter] = data_converter if data_converter
      Temporalio::Worker::WorkflowReplayer.new(**options).replay_workflow(history, raise_on_replay_failure: false)
    end

    # @spec TEMPORAL-ORCHESTRATION-022, PROMPT-EVOLUTION-006
    it "replays both evolution workflows only with Paid's JSON converter" do
      evolution_workflows.each do |workflow_class|
        expect(evolution_replay(workflow_class, data_converter: Paid::TemporalDataConverter.new).replay_failure).to be_nil
        expect(evolution_replay(workflow_class).replay_failure).to be_a(Temporalio::Workflow::NondeterminismError)
      end
    end

    def execute_evolution_workflows
      statuses = []
      Temporalio::Testing::WorkflowEnvironment.start_time_skipping(
        data_converter: Paid::TemporalDataConverter.new
      ) do |environment|
        worker = Temporalio::Worker.new(
          client: environment.client,
          task_queue: Paid.agent_task_queue,
          activities: described_class.activity_definitions,
          workflows: evolution_workflows,
          workflow_failure_exception_types: [ Exception ]
        )
        worker_thread = Thread.new { worker.run }

        evolution_workflows.each do |workflow_class|
          scenario = described_class.scenario_for(workflow_class)
          handle = environment.client.start_workflow(
            workflow_class,
            scenario.input,
            id: "evolution-codec-#{workflow_class.name.demodulize.underscore}",
            task_queue: Paid.agent_task_queue
          )

          statuses << handle.result.fetch("status")
        end
      ensure
        worker_thread&.kill
        worker_thread&.join
      end
      statuses
    end

    # @spec TEMPORAL-ORCHESTRATION-022, PROMPT-EVOLUTION-006
    it "executes both evolution workflows through a supported Temporal server with the Paid converter" do
      expect(execute_evolution_workflows).to all(be_present)
    end
  end

  # Pre-#5288 ("legacy") follow-up review-resolution histories. These record the
  # ResolveReviewThreadsActivity command in its ORIGINAL position — before
  # MarkAgentRunComplete on the no-change path, and right after PushBranch on
  # the changed-head path — with no evidence-backed patch marker. Replaying them
  # against current code (real `patched` returns false for the markerless guard)
  # must reproduce that exact sequence, proving the compatibility branch keeps
  # #5288 replay-safe. Regenerate with
  # script/temporal/export_review_followup_histories.rb.
  # @spec FOCUSED-RUN-011, TEMPORAL-ORCHESTRATION-010
  describe "legacy follow-up review-resolution replay" do
    let(:legacy_fixture_dir) { Rails.root.join("spec/fixtures/temporal/review_followup_replay_histories") }

    def legacy_history(name)
      Temporalio::WorkflowHistory.from_history_json(legacy_fixture_dir.join("#{name}.json").read)
    end

    def scheduled_activity_names(history)
      history.events.filter_map(&:activity_task_scheduled_event_attributes)
        .map { |activity| activity.activity_type.name }
    end

    def replay_failure_for(history)
      Temporalio::Worker::WorkflowReplayer.new(
        workflows: [ Workflows::AgentExecutionWorkflow ],
        data_converter: Paid::TemporalDataConverter.new,
        logger: Logger.new(nil),
        workflow_failure_exception_types: [ Exception ]
      ).replay_workflow(history, raise_on_replay_failure: false).replay_failure
    end

    it "records resolution before completion in the no-change history" do
      names = scheduled_activity_names(legacy_history("agent_execution_legacy_no_change_review_followup"))

      expect(names).to include("ResolveReviewThreads", "MarkAgentRunComplete")
      expect(names.index("ResolveReviewThreads")).to be < names.index("MarkAgentRunComplete")
    end

    it "replays the legacy no-change resolution without non-determinism" do
      expect(replay_failure_for(legacy_history("agent_execution_legacy_no_change_review_followup"))).to be_nil
    end

    it "records resolution after push in the changed-head history" do
      names = scheduled_activity_names(legacy_history("agent_execution_legacy_changed_head_review_followup"))

      expect(names).to include("PushBranch", "ResolveReviewThreads")
      expect(names.index("PushBranch")).to be < names.index("ResolveReviewThreads")
    end

    it "replays the legacy changed-head resolution without non-determinism" do
      expect(replay_failure_for(legacy_history("agent_execution_legacy_changed_head_review_followup"))).to be_nil
    end
  end
end
