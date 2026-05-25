# frozen_string_literal: true

class AddMutationKillRateToQualityMetrics < ActiveRecord::Migration[8.1]
  def change
    add_column :quality_metrics, :mutation_kill_rate, :decimal,
      precision: 5,
      scale: 4,
      comment: "Mutant kill rate for the agent run when mutation testing executed; nil means mutant did not run or produced no score."
  end
end
