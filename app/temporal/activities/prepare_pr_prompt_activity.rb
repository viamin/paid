# frozen_string_literal: true

require "digest"

module Activities
  # Builds a rich prompt for an existing PR run and stores it in custom_prompt.
  #
  # Gathers CI failures, review threads, conversation comments, and optionally
  # linked issue requirements. The generated prompt is written to custom_prompt
  # so that RunAgentActivity picks it up via effective_prompt without changes.
  # Records which prompt builder path ran so PR throughput and token spend can
  # be compared during PromptAssembly rollout.
  class PreparePrPromptActivity < BaseActivity
    activity_name "PreparePrPrompt"
    PROMPT_COMPARISON_SAMPLE_BYTES = 50_000

    def execute(input)
      agent_run_id = input[:agent_run_id]
      rebase_succeeded = input.fetch(:rebase_succeeded, true)
      agent_run = AgentRun.find(agent_run_id)
      focus = input[:focus].presence || agent_run.focus.presence || "general"
      project = agent_run.project
      prompt_builder_path = prompt_builder_for(project)
      service_environment_prompt_blocks = Prompts::BuildForPr.service_environment_section_render_for(
        project: project,
        include_setup_instruction: false
      ).prompt_blocks

      phase_metadata = {
        service_environment_prompt_blocks: service_environment_prompt_blocks,
        prompt_builder: prompt_builder_path
      }

      track_phase(
        agent_run_id: agent_run_id,
        phase_key: "prepare_pr_prompt",
        phase_group: "prompt",
        agent_run: agent_run,
        metadata: phase_metadata
      ) do
        client = project.client
        prompt_version = Prompts::Resolve.call(
          slug: Prompts::BuildForPr::PROMPT_SLUG,
          project: project
        )

        prompt_builder = build_prompt_builder(
          project: project,
          agent_run: agent_run,
          client: client,
          rebase_succeeded: rebase_succeeded,
          prompt_version: prompt_version,
          focus: focus,
          prompt_builder: prompt_builder_path
        )
        result = prompt_builder.build_result if prompt_builder.prompt_assembly?
        phase_metadata[:prompt_assembly] = build_prompt_assembly_provenance(result) if result
        raise_review_feedback_context_blocked! if prompt_builder.review_feedback_context_blocked?

        prompt = prompt_builder.build
        phase_metadata[:prompt_builder_comparison] = build_prompt_builder_comparison(
          project: project,
          agent_run: agent_run,
          client: client,
          rebase_succeeded: rebase_succeeded,
          prompt_version: prompt_version,
          focus: focus,
          served_builder: prompt_builder_path,
          served_prompt: prompt
        ) if FeatureFlags.enabled?(:prompt_assembly_shadow_compare, project: project)
        includes_review_threads = prompt_builder.includes_review_threads?
        review_thread_ids = prompt_builder.unresolved_review_thread_ids

        agent_run.update!(custom_prompt: prompt, prompt_version: prompt_version)
        agent_run.record_prompt_builder!(prompt_builder_path)

        logger.info(
          message: "agent_execution.prepare_pr_prompt",
          agent_run_id: agent_run_id,
          focus: focus,
          prompt_builder: prompt_builder_path,
          prompt_length: prompt.length,
          includes_review_threads: includes_review_threads,
          review_thread_count: review_thread_ids.size,
          prompt_version_id: prompt_version&.id,
          prompt_section_keys: result&.sections&.map { |section| section.key.to_s } || [],
          prompt_excluded_count: result&.skipped&.size || 0,
          prompt_digest: result&.prompt_digest,
          profile_fingerprint: result&.profile_fingerprint
        )

        {
          agent_run_id: agent_run_id,
          prompt_builder: prompt_builder_path,
          prompt_length: prompt.length,
          includes_review_threads: includes_review_threads,
          review_thread_ids: review_thread_ids,
          prompt_version_id: prompt_version&.id,
          prompt_section_keys: result&.sections&.map { |section| section.key.to_s } || [],
          prompt_excluded_count: result&.skipped&.size || 0,
          prompt_digest: result&.prompt_digest,
          profile_fingerprint: result&.profile_fingerprint
        }
      end
    end

    private

    def build_prompt_builder(project:, agent_run:, client:, rebase_succeeded:, prompt_version:, focus:, prompt_builder:)
      Prompts::BuildForPr.new(
        project: project,
        pr_number: agent_run.source_pull_request_number,
        github_client: client,
        rebase_succeeded: rebase_succeeded,
        issue: agent_run.issue,
        prompt_version: prompt_version,
        focus: focus,
        agent_run: agent_run,
        prompt_builder: prompt_builder
      )
    end

    def prompt_builder_for(project)
      if FeatureFlags.enabled?(:prompt_assembly, project: project)
        Prompts::BuildForPr::PROMPT_ASSEMBLY_BUILDER
      else
        Prompts::BuildForPr::LEGACY_PROMPT_BUILDER
      end
    end

    def build_prompt_builder_comparison(project:, agent_run:, client:, rebase_succeeded:, prompt_version:, focus:, served_builder:, served_prompt:)
      legacy_prompt = prompt_for_comparison(
        project:, agent_run:, client:, rebase_succeeded:, prompt_version:, focus:,
        prompt_builder: Prompts::BuildForPr::LEGACY_PROMPT_BUILDER,
        served_builder:, served_prompt:
      )
      assembly_prompt = prompt_for_comparison(
        project:, agent_run:, client:, rebase_succeeded:, prompt_version:, focus:,
        prompt_builder: Prompts::BuildForPr::PROMPT_ASSEMBLY_BUILDER,
        served_builder:, served_prompt:
      )

      {
        "served_builder" => served_builder,
        "legacy_prompt" => prompt_observation(legacy_prompt),
        "prompt_assembly_prompt" => prompt_observation(assembly_prompt),
        "matched" => legacy_prompt == assembly_prompt
      }
    rescue => e
      {
        "served_builder" => served_builder,
        "error_class" => e.class.name,
        "error" => e.message
      }
    end

    def prompt_for_comparison(project:, agent_run:, client:, rebase_succeeded:, prompt_version:, focus:, prompt_builder:, served_builder:, served_prompt:)
      return served_prompt if prompt_builder == served_builder

      build_prompt_builder(
        project:, agent_run:, client:, rebase_succeeded:, prompt_version:, focus:, prompt_builder:
      ).build
    end

    def prompt_observation(prompt)
      prompt_text = prompt.to_s

      {
        "digest" => Digest::SHA256.hexdigest(prompt_text),
        "bytes" => prompt_text.bytesize,
        "sample" => prompt_text.byteslice(0, PROMPT_COMPARISON_SAMPLE_BYTES).to_s.scrub
      }
    end

    def raise_review_feedback_context_blocked!
      raise Temporalio::Error::ApplicationError.new(
        "Review feedback follow-up has unresolved review threads but no prompt-eligible review comments",
        type: "ReviewFeedbackContextBlocked",
        non_retryable: true
      )
    end

    # Serializes a PromptAssembly::Result into a JSON-safe hash for the
    # agent_run_phases.metadata["prompt_assembly"] column. The assembler
    # already strips bodies from skipped sections, so untrusted content
    # never reaches the persisted record.
    def build_prompt_assembly_provenance(result)
      {
        "sections" => result.sections.map do |section|
          {
            "key" => section.key.to_s,
            "source" => section.source&.to_s,
            "trust_level" => section.trust_level.to_s,
            "required" => section.required?,
            "inclusion_reason" => section.inclusion_reason
          }
        end,
        "skipped" => result.skipped.map do |entry|
          entry.transform_keys(&:to_s)
        end,
        "prompt_digest" => result.prompt_digest,
        "profile_fingerprint" => result.profile_fingerprint,
        "budget_decisions" => result.budget_decisions.map do |decision|
          decision.transform_keys(&:to_s)
        end
      }
    end
  end
end
