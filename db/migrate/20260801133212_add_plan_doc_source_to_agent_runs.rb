# frozen_string_literal: true

class AddPlanDocSourceToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :plan_doc_source, :string, limit: 1000,
      comment: "User-named plan document (RDR/ADR/design doc path or URL) the " \
               "lid_planning run treats as authored intent. Only set for lid_planning runs."
  end
end
