# frozen_string_literal: true

class AddNoProgressThresholdsToRunners < ActiveRecord::Migration[8.1]
  def change
    add_column :runners, :no_progress_thresholds, :jsonb,
      null: false,
      default: { "min_input_tokens" => 100_000, "max_output_tokens" => 100 },
      comment: "Per-runner thresholds for no-progress early termination. " \
               "min_input_tokens: minimum input tokens consumed before checking; " \
               "max_output_tokens: maximum output tokens that qualifies as no progress."
  end
end
