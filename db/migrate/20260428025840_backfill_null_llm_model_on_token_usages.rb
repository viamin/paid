# frozen_string_literal: true

# Backfills llm_model on existing token_usages rows that were written with
# nil because the harness response didn't carry a model id. The mapping
# matches the runtime fallback now applied in
# AgentRuns::TrackHarnessTokens#llm_model_label, so legacy rows merge into
# the same dashboard buckets as new rows instead of staying in "Unknown".
class BackfillNullLlmModelOnTokenUsages < ActiveRecord::Migration[8.1]
  # Values are the AgentHarness provider_name symbols (as strings) that the
  # runtime fallback in AgentRuns::TrackHarnessTokens writes via
  # `response.provider.to_s`. Keeping these in sync ensures backfilled rows
  # bucket alongside future writes in the cost dashboard. The "api" agent
  # type is intentionally omitted — its harness provider returns nil for
  # provider_name, so the runtime fallback also leaves llm_model nil.
  AGENT_TYPE_TO_PROVIDER = {
    "claude_code" => "claude",
    "cursor" => "cursor",
    "codex" => "codex",
    "copilot" => "github_copilot",
    "aider" => "aider",
    "gemini" => "gemini",
    "opencode" => "opencode",
    "kilocode" => "kilocode"
  }.freeze

  def up
    TenantContext.with_system_access do
      AGENT_TYPE_TO_PROVIDER.each do |agent_type, provider_label|
        execute(ActiveRecord::Base.sanitize_sql_array([ <<~SQL, provider_label, agent_type ]))
          UPDATE token_usages
          SET llm_model = ?
          FROM agent_runs
          WHERE token_usages.agent_run_id = agent_runs.id
            AND token_usages.llm_model IS NULL
            AND agent_runs.agent_type = ?
        SQL
      end
    end
  end

  # Forward-only: rolling back the version is fine; the backfilled values
  # stay in place. Re-running #up is idempotent because of the IS NULL
  # filter and merges cleanly with rows already labeled by the runtime path.
  def down; end
end
