# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationBundles::RecordOutcome, :no_db do
  let(:project) { Object.new }
  let(:configuration_bundle) { Object.new }
  let(:quality_metric) { Struct.new(:composite_score, :scores).new(0.84, { "pr_created" => 1.0 }) }
  let(:agent_run) do
    Struct.new(
      :configuration_bundle,
      :project,
      :tokens_input,
      :tokens_output,
      :created_at,
      :started_at,
      :completed_at,
      :cost_cents,
      :duration_seconds,
      :status,
      :configuration_bundle_selection_mode,
      :configuration_bundle_selection_context
    ).new(
      configuration_bundle,
      project,
      100,
      50,
      Time.utc(2026, 5, 14, 12, 0, 0),
      Time.utc(2026, 5, 14, 12, 1, 0),
      Time.utc(2026, 5, 14, 12, 3, 30),
      150,
      150,
      "completed",
      "exploratory",
      "project"
    )
  end
  let(:objective_result) do
    ConfigurationBundles::ObjectiveScore::Result.new(
      objective_score: 0.684,
      quality_score: 0.84,
      cost_score: 0.6,
      speed_score: 0.7,
      quality_per_dollar: 0.56
    )
  end
  let(:outcome) do
    Class.new do
      attr_reader :attributes

      def assign_attributes(attributes)
        @attributes = attributes
      end

      def save!; end
    end.new
  end
  let(:bundle_outcome_class) do
    Class.new do
      class << self
        attr_accessor :returned_outcome

        def find_or_initialize_by(*)
          returned_outcome
        end
      end
    end
  end

  before do
    stub_const("BundleOutcome", bundle_outcome_class)
    bundle_outcome_class.returned_outcome = outcome
    allow(ConfigurationBundles::ObjectiveScore).to receive(:call).and_return(objective_result)
  end

  it "stores exploration metadata with the recorded bundle outcome" do
    described_class.call(agent_run: agent_run, quality_metric: quality_metric)

    expect(outcome.attributes).to include(
      quality_score: 0.84,
      success: true,
      metrics: hash_including(
        "exploratory" => true,
        "selection_context" => "project",
        "selection_mode" => "exploratory",
        "objective_score" => 0.684,
        "queue_duration_seconds" => 60,
        "total_duration_seconds" => 210
      )
    )
  end

  context "when selection_mode is nil (optimizer skipped)" do
    let(:agent_run) do
      Struct.new(
        :configuration_bundle,
        :project,
        :tokens_input,
        :tokens_output,
        :created_at,
        :started_at,
        :completed_at,
        :cost_cents,
        :duration_seconds,
        :status,
        :configuration_bundle_selection_mode,
        :configuration_bundle_selection_context
      ).new(
        configuration_bundle,
        project,
        100,
        50,
        Time.utc(2026, 5, 14, 12, 0, 0),
        Time.utc(2026, 5, 14, 12, 1, 0),
        Time.utc(2026, 5, 14, 12, 3, 30),
        150,
        150,
        "completed",
        nil,
        nil
      )
    end

    it "leaves exploratory nil instead of defaulting to false" do
      described_class.call(agent_run: agent_run, quality_metric: quality_metric)

      metrics = outcome.attributes[:metrics]
      expect(metrics).not_to have_key("exploratory")
      expect(metrics).not_to have_key("selection_mode")
      expect(metrics).not_to have_key("selection_context")
    end
  end
end
