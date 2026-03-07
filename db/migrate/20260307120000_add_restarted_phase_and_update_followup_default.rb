# frozen_string_literal: true

class AddRestartedPhaseAndUpdateFollowupDefault < ActiveRecord::Migration[8.1]
  def change
    change_column_default :projects, :max_pr_followup_runs, from: 3, to: 8
  end
end
