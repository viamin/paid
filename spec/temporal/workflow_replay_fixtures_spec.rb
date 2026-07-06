# frozen_string_literal: true

require "rails_helper"
require "json"
require "temporalio/worker"
require "temporalio/worker/workflow_replayer"
require "temporalio/workflow_history"

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

  described_class.workflow_classes.each do |workflow_class|
    it "replays #{workflow_class.name.demodulize} from its saved history" do
      history = Temporalio::WorkflowHistory.from_history_json(
        fixture_dir.join("#{workflow_class.name.demodulize.underscore}.json").read
      )

      result = Temporalio::Worker::WorkflowReplayer.new(
        workflows: [ workflow_class ],
        logger: Logger.new(nil),
        workflow_failure_exception_types: [ Exception ]
      ).replay_workflow(history, raise_on_replay_failure: false)

      expect(result.replay_failure).to be_nil
    end
  end
end
