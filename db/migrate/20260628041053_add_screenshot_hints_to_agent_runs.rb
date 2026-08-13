# frozen_string_literal: true

class AddScreenshotHintsToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :screenshot_hints, :jsonb, default: {}, null: false,
      comment: "Per-route screenshot hints derived from the agent's change (route name => {summary, selector}). " \
               "Used to scope and annotate UI screenshots to what the agent actually changed."
  end
end
