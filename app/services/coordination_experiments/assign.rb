# frozen_string_literal: true

require "zlib"

module CoordinationExperiments
  class Assign
    def self.call(...)
      new(...).call
    end

    def initialize(coordination_experiment:, project:, workflow_id:, issue: nil)
      @coordination_experiment = coordination_experiment
      @project = project
      @workflow_id = workflow_id
      @issue = issue
    end

    def call
      raise ArgumentError, "coordination experiment is not running" unless coordination_experiment.running?

      existing = CoordinationExperimentAssignment.find_by(
        coordination_experiment: coordination_experiment,
        workflow_id: workflow_id
      )
      return existing if existing

      CoordinationExperimentAssignment.create!(
        coordination_experiment: coordination_experiment,
        coordination_experiment_variant: select_variant,
        project: project,
        issue: issue,
        workflow_id: workflow_id
      )
    rescue ActiveRecord::RecordNotUnique
      CoordinationExperimentAssignment.find_by!(
        coordination_experiment: coordination_experiment,
        workflow_id: workflow_id
      )
    end

    private

    attr_reader :coordination_experiment, :project, :workflow_id, :issue

    def select_variant
      variants = coordination_experiment.coordination_experiment_variants.order(:id).to_a
      raise ArgumentError, "coordination experiment has no variants" if variants.empty?

      counts = CoordinationExperimentAssignment
        .where(coordination_experiment:, coordination_experiment_variant: variants)
        .group(:coordination_experiment_variant_id)
        .count
      min_count = variants.map { |variant| counts.fetch(variant.id, 0) }.min
      candidates = variants.select { |variant| counts.fetch(variant.id, 0) == min_count }
      candidates[Zlib.crc32("#{coordination_experiment.id}:#{workflow_id}") % candidates.size]
    end
  end
end
