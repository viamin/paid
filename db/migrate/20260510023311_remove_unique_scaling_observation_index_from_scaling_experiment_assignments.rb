# frozen_string_literal: true

class RemoveUniqueScalingObservationIndexFromScalingExperimentAssignments < ActiveRecord::Migration[8.1]
  def change
    remove_index :scaling_experiment_assignments,
      name: "idx_scaling_experiment_assignments_observation_unique"

    add_index :scaling_experiment_assignments,
      :scaling_observation_id,
      name: "idx_scaling_experiment_assignments_observation"
  end
end
