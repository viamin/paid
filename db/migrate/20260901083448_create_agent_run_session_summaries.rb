# frozen_string_literal: true

class CreateAgentRunSessionSummaries < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_run_session_summaries,
      comment: "Synthesized session-summary knowledge observations captured after selected agent runs." do |t|
      t.references :project, null: false, foreign_key: { on_delete: :cascade },
        comment: "Project the summarized agent run belongs to."
      t.references :agent_run, null: false, foreign_key: { on_delete: :cascade }, index: false,
        comment: "Agent run this summary was synthesized from."
      t.references :issue, foreign_key: { on_delete: :nullify },
        comment: "Issue the agent run worked on, when applicable."
      t.string :status, limit: 50, default: "observation", null: false,
        comment: "Lifecycle state: observation (raw capture) or promoted (accepted into durable intent)."
      t.text :summary, null: false, comment: "Narrative summary of what happened during the agent run."
      t.jsonb :files_touched, default: [], null: false, comment: "File paths created, modified, or investigated."
      t.jsonb :decisions, default: [], null: false, comment: "Decisions the agent made and why."
      t.jsonb :assumptions, default: [], null: false, comment: "Assumptions the agent made when information was incomplete."
      t.jsonb :failures, default: [], null: false, comment: "Approaches that were tried and failed, or errors encountered."
      t.jsonb :follow_ups, default: [], null: false, comment: "Follow-up work identified but not completed in this run."
      t.jsonb :learnings, default: [], null: false, comment: "Reusable insights about the repository or codebase."
      t.integer :pull_request_number, comment: "Pull request number produced or updated by the run, when applicable."
      t.string :pull_request_url, comment: "Pull request URL produced or updated by the run, when applicable."
      t.datetime :generated_at, comment: "When the LLM synthesis that produced this summary completed."
      t.datetime :promoted_at, comment: "When this observation was promoted to a durable Change Intent Record."
      t.references :promoted_by, foreign_key: { to_table: :users, on_delete: :nullify },
        comment: "User who promoted this observation, when applicable."
      t.references :change_intent, foreign_key: { on_delete: :nullify },
        comment: "Change Intent Record created when this observation was promoted."

      t.timestamps
    end

    add_index :agent_run_session_summaries, :agent_run_id, unique: true
    add_index :agent_run_session_summaries, [ :project_id, :created_at ]
    add_index :agent_run_session_summaries, [ :project_id, :status ]
  end
end
