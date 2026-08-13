# frozen_string_literal: true

class RunProvenanceBuilder
  def initialize(agent_run)
    @agent_run = agent_run
  end

  def build
    {
      run: run_summary,
      prompt: prompt_provenance,
      prompt_assembly: prompt_assembly_provenance,
      model: model_provenance,
      tools: tool_provenance,
      code_changes: code_provenance,
      approvals: approval_provenance,
      timeline: timeline_provenance,
      costs: cost_provenance,
      runner_attempts: runner_attempt_provenance
    }
  end

  private

  attr_reader :agent_run

  def run_summary
    {
      id: agent_run.id,
      agent_type: agent_run.agent_type,
      goal: agent_run.goal,
      focus: agent_run.focus,
      status: agent_run.status,
      trigger_type: agent_run.trigger_type,
      created_at: agent_run.created_at&.iso8601,
      started_at: agent_run.started_at&.iso8601,
      completed_at: agent_run.completed_at&.iso8601,
      duration_seconds: agent_run.duration_seconds,
      iterations: agent_run.iterations,
      turns_completed: agent_run.turns_completed,
      error_message: agent_run.error_message,
      initiating_user_id: agent_run.initiating_user_id,
      project_id: agent_run.project_id,
      issue_id: agent_run.issue_id
    }
  end

  def prompt_provenance
    prompt_version = agent_run.prompt_version
    custom_prompt = agent_run.custom_prompt

    {
      source: prompt_version ? "versioned" : (custom_prompt ? "custom" : "none"),
      prompt_version_id: prompt_version&.id,
      prompt_id: prompt_version&.prompt_id,
      prompt_slug: prompt_version&.prompt&.slug,
      version_number: prompt_version&.version,
      created_by_user_id: prompt_version&.created_by_user_id,
      review_status: prompt_version&.review_status,
      reviewed_by_user_id: prompt_version&.reviewed_by_user_id,
      reviewed_at: prompt_version&.reviewed_at&.iso8601,
      custom_prompt_truncated: custom_prompt&.truncate(200),
      service_environment_prompt_blocks: service_environment_prompt_blocks
    }
  end

  def service_environment_prompt_blocks
    phase = prompt_assembly_phases.find do |candidate|
      service_environment_prompt_blocks_for(candidate).present?
    end
    blocks = phase && service_environment_prompt_blocks_for(phase)
    Array(blocks).map { |block| block.respond_to?(:deep_symbolize_keys) ? block.deep_symbolize_keys : block }
  end

  def prompt_assembly_provenance
    metadata = prompt_assembly_metadata
    return nil unless metadata

    sections = Array(metadata["sections"])
    skipped = Array(metadata["skipped"])
    trusted = sections.count { |s| s["trust_level"] == "trusted" }
    quarantined = sections.count { |s| s["trust_level"] == "quarantined" }
    excluded = skipped.count { |s| s["trust_level"] == "excluded" }

    {
      sections: sections.map { |s| s.respond_to?(:deep_symbolize_keys) ? s.deep_symbolize_keys : s },
      skipped: skipped.map { |s| s.respond_to?(:deep_symbolize_keys) ? s.deep_symbolize_keys : s },
      prompt_digest: metadata["prompt_digest"],
      profile_fingerprint: metadata["profile_fingerprint"],
      budget_decisions: Array(metadata["budget_decisions"]).map { |d| d.respond_to?(:deep_symbolize_keys) ? d.deep_symbolize_keys : d },
      trusted_content_count: trusted,
      quarantined_content_count: quarantined,
      excluded_content_count: excluded
    }
  end

  def prompt_assembly_metadata
    phase = prompt_assembly_phases.find { |candidate| candidate.metadata&.key?("prompt_assembly") }
    phase&.metadata&.dig("prompt_assembly")
  end

  def prompt_assembly_phases
    @prompt_assembly_phases ||= %w[prepare_pr_prompt create_agent_run].filter_map do |phase_key|
      agent_run.agent_run_phases.find { |phase| phase.phase_key == phase_key }
    end
  end

  def service_environment_prompt_blocks_for(phase)
    metadata = phase.metadata
    metadata&.fetch("service_environment_prompt_blocks", metadata[:service_environment_prompt_blocks])
  end

  def model_provenance
    selection = agent_run.model_selection
    llm_model = selection&.llm_model

    {
      selector_type: selection&.selector_type,
      llm_model_id: selection&.llm_model_id,
      model_id: llm_model&.model_id,
      provider: llm_model&.provider,
      tier: selection&.tier,
      complexity_score: selection&.complexity_score,
      escalated_from_tier: selection&.escalated_from_tier,
      escalated_reason: selection&.escalated_reason,
      reasoning: selection&.reasoning,
      selection_duration_ms: selection&.selection_duration_ms
    }
  end

  def tool_provenance
    snapshot = agent_run.mcp_server_snapshot
    {
      servers_count: snapshot.size,
      servers: snapshot.map { |s|
        {
          name: s["name"],
          command: s["command"],
          args: s["args"],
          env_keys: s["env"]&.keys || []
        }
      },
      provisioned_servers_count: agent_run.mcp_provisioned_servers.size,
      sidecar_container_ids: agent_run.mcp_sidecar_container_ids
    }
  end

  def code_provenance
    {
      base_commit_sha: agent_run.base_commit_sha,
      result_commit_sha: agent_run.result_commit_sha,
      branch_name: agent_run.branch_name,
      pull_request_url: agent_run.pull_request_url,
      pull_request_number: agent_run.pull_request_number,
      created_issue_url: agent_run.created_issue_url,
      created_issue_number: agent_run.created_issue_number,
      source_pull_request_number: agent_run.source_pull_request_number,
      cross_repo_issues: agent_run.cross_repo_issues,
      decision_records: decision_record_provenance
    }
  end

  def decision_record_provenance
    agent_records = if agent_run.project.respond_to?(:decision_records)
                       agent_run.project.decision_records.where(agent_run_id: agent_run.id)
    else
                       []
    end

    agent_records.map { |dr|
      {
        id: dr.id,
        title: dr.title,
        decision: dr.decision,
        status: dr.status,
        commit_sha_start: dr.commit_sha_start,
        commit_sha_end: dr.commit_sha_end,
        tags: dr.tags
      }
    }
  end

  def approval_provenance
    prompt_version = agent_run.prompt_version
    return nil unless prompt_version

    {
      review_status: prompt_version.review_status,
      reviewed_by_user_id: prompt_version.reviewed_by_user_id,
      reviewed_at: prompt_version.reviewed_at&.iso8601,
      review_notes: prompt_version.review_notes,
      change_notes: prompt_version.change_notes,
      created_by_user_id: prompt_version.created_by_user_id,
      parent_version_id: prompt_version.parent_version_id
    }
  end

  def timeline_provenance
    agent_run.agent_run_phases.map { |phase|
      {
        phase_key: phase.phase_key,
        phase_group: phase.phase_group,
        status: phase.status,
        started_at: phase.started_at&.iso8601,
        finished_at: phase.finished_at&.iso8601,
        duration_seconds: phase.duration_seconds
      }
    }
  end

  def cost_provenance
    {
      tokens_input: agent_run.tokens_input,
      tokens_output: agent_run.tokens_output,
      cost_cents: agent_run.cost_cents,
      token_usages: agent_run.token_usages.map { |tu|
        {
          request_type: tu.request_type,
          input_tokens: tu.input_tokens,
          output_tokens: tu.output_tokens,
          cost_cents: tu.cost_cents,
          llm_model: tu.llm_model
        }
      }
    }
  end

  def runner_attempt_provenance
    attempts = agent_run.runners_attempted
    {
      final_runner: agent_run.final_runner,
      runner_switches: agent_run.runner_switches,
      attempts: attempts.map { |a|
        {
          runner_key: a["runner_key"],
          success: a["success"],
          error_type: a["error_type"],
          resolved_model_id: a["resolved_model_id"],
          resolved_provider_id: a["resolved_provider_id"]
        }
      }
    }
  end
end
