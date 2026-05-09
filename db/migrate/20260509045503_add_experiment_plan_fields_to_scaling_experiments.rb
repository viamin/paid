# frozen_string_literal: true

class AddExperimentPlanFieldsToScalingExperiments < ActiveRecord::Migration[8.1]
  def change
    add_column :scaling_experiments,
      :independent_variables,
      :jsonb,
      null: false,
      default: [],
      comment: "Declared primary and contextual variables for the controlled scaling plan, including the tested arm values."
    add_column :scaling_experiments,
      :outcome_metrics,
      :jsonb,
      null: false,
      default: [],
      comment: "Outcome metrics tracked for the experiment plan, including optimization direction and primary-vs-guardrail roles."
    add_column :scaling_experiments,
      :control_definition,
      :jsonb,
      null: false,
      default: {},
      comment: "Control conditions and fairness guardrails that must hold for cohort-to-cohort comparisons."
    add_column :scaling_experiments,
      :cohort_settings,
      :jsonb,
      null: false,
      default: {},
      comment: "Scheduling and labeling rules for experiment cohorts, such as task buckets and label templates."
  end
end
