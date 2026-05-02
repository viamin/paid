# frozen_string_literal: true

class AddStreamingTurnMetricsToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :turns_completed, :integer, default: 0, null: false,
      comment: "Number of agent turns completed, tracked via streaming JSONL progress events"
    add_column :agent_runs, :streaming_turns_data, :jsonb, default: [], null: false,
      comment: "Per-turn metrics from streaming JSONL events (turn number, tokens, duration)"
  end
end
