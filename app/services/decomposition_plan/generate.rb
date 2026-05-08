# frozen_string_literal: true

module DecompositionPlan
  # Generates a structured decomposition plan from scope analysis output.
  #
  # Takes an issue's scope analysis (sub_components list and text) and produces
  # an ordered list of sub-issues with explicit dependencies forming a valid DAG.
  #
  # Ordering follows layered dependency principles:
  #   1. Data model (migrations, models) - no dependencies
  #   2. Service layer (business logic) - depends on models
  #   3. API/controller layer - depends on services
  #   4. Frontend/views - depends on controllers
  #
  # Each sub-issue includes its own tests within scope.
  #
  # @example
  #   result = DecompositionPlan::Generate.call(
  #     title: "User notification system",
  #     description: issue.body,
  #     sub_components: scope_result.sub_components
  #   )
  #   result.tasks   # => [{ title: "...", deps: [], scope: "model" }, ...]
  #   result.valid?  # => true
  class Generate
    DEFAULT_LAYER_ORDER = {
      "model" => 0,
      "service" => 1,
      "controller" => 2,
      "view" => 3
    }.freeze
    LAYER_ORDER = DEFAULT_LAYER_ORDER

    MAX_DESCRIPTION_LENGTH = 5000
    MAX_TITLE_LENGTH = 255
    MAX_TASKS = 20

    attr_reader :title, :description, :sub_components, :max_tasks, :layer_order

    def initialize(title:, description:, sub_components:, max_tasks: MAX_TASKS, layer_order: DEFAULT_LAYER_ORDER.keys)
      @title = title.to_s
      @description = description.to_s
      @sub_components = Array(sub_components)
      @max_tasks = normalize_max_tasks(max_tasks)
      @layer_order = normalize_layer_order(layer_order)
    end

    def self.call(...)
      new(...).call
    end

    def call
      tasks = build_tasks
      tasks = enforce_layer_ordering(tasks)
      tasks = enforce_max_tasks(tasks)
      tasks = assign_indices(tasks)

      validation = ValidateDag.call(tasks: tasks)
      unless validation.valid?
        tasks = repair_dag(tasks)
        validation = ValidateDag.call(tasks: tasks)
      end

      Result.new(
        tasks: deep_freeze(tasks),
        valid: validation.valid?,
        sorted_indices: validation.sorted_indices,
        errors: validation.errors
      )
    end

    private

    def build_tasks
      grouped = group_components_by_layer
      tasks = []

      grouped.each do |layer, components|
        tasks << build_task_for_layer(layer, components)
      end

      tasks = [ build_single_task ] if tasks.empty?
      tasks
    end

    def group_components_by_layer
      grouped = {}

      sub_components.each do |component|
        layer = classify_component(component)
        next unless layer

        (grouped[layer] ||= []) << component
      end

      grouped
    end

    def classify_component(component)
      case component.to_s.downcase
      when "migrations", "database", "models"
        "model"
      when "service layer", "background jobs", "notifications", "caching",
           "authentication", "authorization", "email"
        "service"
      when "web controllers", "api endpoints", "routing"
        "controller"
      when "views", "ui", "helpers"
        "view"
      when "tests", "specs", "testing"
        # Tests are included within each layer's guidance already; skip as a
        # standalone layer to avoid nonsensical "Implement service layer: tests" tasks.
        nil
      else
        "service"
      end
    end

    def build_task_for_layer(layer, components)
      component_list = components.join(", ")
      {
        title: "#{layer_verb(layer)} #{component_list} for #{title}".truncate(MAX_TITLE_LENGTH),
        description: "Implement #{component_list}. #{layer_guidance(layer)}".truncate(MAX_DESCRIPTION_LENGTH),
        scope: layer,
        deps: [],
        _layer_order: layer_rank_for(layer)
      }
    end

    def build_single_task
      {
        title: title.truncate(MAX_TITLE_LENGTH),
        description: description.truncate(MAX_DESCRIPTION_LENGTH),
        scope: "service",
        deps: [],
        _layer_order: layer_rank_for("service")
      }
    end

    def layer_verb(layer)
      case layer
      when "model" then "Add data model and migrations for"
      when "service" then "Implement service layer:"
      when "controller" then "Add API endpoints for"
      when "view" then "Build UI views for"
      else "Implement"
      end
    end

    def layer_guidance(layer)
      case layer
      when "model"
        "Create database migrations and ActiveRecord models with validations and associations. Include model specs."
      when "service"
        "Build service objects encapsulating business logic. Include unit tests for each service."
      when "controller"
        "Add controller actions and routes. Include request specs for each endpoint."
      when "view"
        "Build view components and templates. Include view/system specs."
      else
        "Include tests for the implemented functionality."
      end
    end

    # Sort tasks by layer order and wire up dependencies so each layer
    # depends on all tasks from preceding layers.
    def enforce_layer_ordering(tasks)
      tasks.sort_by { |t| t[:_layer_order] }
    end

    def enforce_max_tasks(tasks)
      tasks.first(max_tasks)
    end

    def assign_indices(tasks)
      # Group tasks by layer order to build dependency edges
      layer_groups = {}
      tasks.each_with_index do |task, index|
        order = task[:_layer_order]
        (layer_groups[order] ||= []) << index
      end

      sorted_orders = layer_groups.keys.sort
      prev_group_indices = []

      sorted_orders.each do |order|
        indices = layer_groups[order]
        indices.each do |index|
          tasks[index][:deps] = prev_group_indices.dup
        end
        prev_group_indices = indices
      end

      # Clean up internal keys and freeze
      tasks.each_with_index.map do |task, index|
        {
          title: task[:title],
          description: task[:description],
          scope: task[:scope],
          deps: task[:deps],
          index: index
        }
      end
    end

    def deep_freeze(tasks)
      tasks.each { |task| task.each_value { |v| v.freeze unless v.frozen? }.freeze }
      tasks.freeze
    end

    def normalize_max_tasks(value)
      Integer(value).clamp(1, MAX_TASKS)
    rescue ArgumentError, TypeError
      MAX_TASKS
    end

    def normalize_layer_order(value)
      requested_layers = Array(value).filter_map do |layer|
        normalized = layer.to_s
        normalized if DEFAULT_LAYER_ORDER.key?(normalized)
      end

      ordered_layers = (requested_layers + DEFAULT_LAYER_ORDER.keys).uniq
      ordered_layers.each_with_index.to_h
    end

    def layer_rank_for(layer)
      layer_order.fetch(layer, DEFAULT_LAYER_ORDER.size)
    end

    # TODO(#453): Split tasks covering too many components into smaller tasks
    # within the same layer when we have room under MAX_TASKS.

    # Attempt to fix DAG issues by removing problematic dependency edges.
    def repair_dag(tasks)
      tasks.map do |task|
        valid_deps = Array(task[:deps]).select do |dep|
          dep.is_a?(Integer) && dep >= 0 && dep < tasks.size && dep != task[:index]
        end
        task.merge(deps: valid_deps)
      end
    end

    class Result
      attr_reader :tasks, :sorted_indices, :errors

      def initialize(tasks:, valid:, sorted_indices:, errors:)
        @tasks = tasks
        @valid = valid
        @sorted_indices = sorted_indices
        @errors = errors
      end

      def valid?
        @valid
      end

      def task_count
        tasks.size
      end
    end
  end
end
