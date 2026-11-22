# frozen_string_literal: true

class AddDeploymentRevisionToWorkerReadinessObservations < ActiveRecord::Migration[8.1]
  def change
    add_column :worker_readiness_observations, :deployment_revision, :string,
      comment: "Complete deployment identity observed when the worker booted."
  end
end
