# frozen_string_literal: true

module ScalingExperiments
  class Create
    DEFAULT_CONTEXT_FILTER = {
      "min_task_count" => 2
    }.freeze

    def self.call(...)
      new(...).call
    end

    def initialize(project:, name:, hypothesis:, values_tested:, control_value:, min_samples_per_value: 2,
      traffic_percentage: 100, context_filter: {}, dimension: "agent_count")
      @project = project
      @name = name
      @hypothesis = hypothesis
      @values_tested = values_tested
      @control_value = control_value
      @min_samples_per_value = min_samples_per_value
      @traffic_percentage = traffic_percentage
      @context_filter = context_filter
      @dimension = dimension
    end

    def call
      ScalingExperiment.create!(
        project: project,
        name: name,
        hypothesis: hypothesis,
        dimension: dimension,
        values_tested: Array(values_tested).map { |value| Integer(value) }.uniq.sort,
        control_value: Integer(control_value),
        min_samples_per_value: min_samples_per_value,
        traffic_percentage: traffic_percentage,
        context_filter: normalized_context_filter
      )
    end

    private

    attr_reader :project, :name, :hypothesis, :values_tested, :control_value, :min_samples_per_value,
      :traffic_percentage, :context_filter, :dimension

    def normalized_context_filter
      DEFAULT_CONTEXT_FILTER.merge((context_filter || {}).deep_stringify_keys)
    end
  end
end
