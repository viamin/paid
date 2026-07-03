# frozen_string_literal: true

require "rails_helper"
require "temporalio/worker"
require "temporalio/worker/workflow_replayer"
require "temporalio/workflow_history"

module WorkflowReplayFixtures
  WORKFLOW_CLASSES = Workflows.constants.map { |const| Workflows.const_get(const) }
    .select { |klass| klass.is_a?(Class) && klass < Workflows::BaseWorkflow }
    .reject { |klass| klass == Workflows::BaseWorkflow }
    .sort_by(&:name)
end

RSpec.describe WorkflowReplayFixtures, :no_db do
  let(:fixture_dir) { Rails.root.join("spec/fixtures/temporal/replay_histories") }

  it "has a saved history fixture for every workflow" do
    fixture_names = Dir.glob(fixture_dir.join("*.json")).map { |path| File.basename(path, ".json") }.sort
    workflow_names = described_class::WORKFLOW_CLASSES.map { |klass| klass.name.demodulize.underscore }.sort

    expect(fixture_names).to eq(workflow_names)
  end

  described_class::WORKFLOW_CLASSES.each do |workflow_class|
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
