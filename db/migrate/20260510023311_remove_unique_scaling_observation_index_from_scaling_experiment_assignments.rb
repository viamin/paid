# frozen_string_literal: true

class RemoveUniqueScalingObservationIndexFromScalingExperimentAssignments < ActiveRecord::Migration[8.1]
  def up
    remove_index :scaling_experiment_assignments,
      name: "idx_scaling_experiment_assignments_observation_unique"

    add_index :scaling_experiment_assignments,
      :scaling_observation_id,
      where: "scaling_observation_id IS NOT NULL",
      name: "idx_scaling_experiment_assignments_observation"
  end

  def down
    remove_index :scaling_experiment_assignments,
      name: "idx_scaling_experiment_assignments_observation"

    add_index :scaling_experiment_assignments,
      :scaling_observation_id,
      name: "idx_scaling_experiment_assignments_observation_unique",
      unique: true,
      where: "scaling_observation_id IS NOT NULL"
  end
end
