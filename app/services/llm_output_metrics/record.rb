# frozen_string_literal: true

module LlmOutputMetrics
  # Records an initial LlmOutputMetric when an LLM output is generated.
  # Called inline from the generation services (GeneratePrDescription,
  # GenerateIssueTitle, Knowledge::Decisions::Draft) after a successful
  # LLM call produces output.
  #
  # @example
  #   LlmOutputMetrics::Record.call(
  #     project: project,
  #     output_type: "pr_description",
  #     prompt_slug: "generation.pr_description",
  #     source_type: "PullRequest",
  #     source_id: 42
  #   )
  class Record
    def self.call(...)
      new(...).call
    end

    # @param prompt_project [Project, nil] When set, prompt version is resolved
    #   via Prompt.resolve (project > account > global), matching
    #   Prompts::Render.call(project: ...). When nil, resolution uses
    #   global-only lookup, matching Prompts::Render.call without project:.
    #   Callers must pass the same project here that they passed (or omitted)
    #   when rendering, so the recorded version matches the rendered one.
    def initialize(project:, output_type:, prompt_slug:, source_type:, source_id:, prompt_project: nil, metadata: {})
      @project = project
      @output_type = output_type
      @prompt_slug = prompt_slug
      @source_type = source_type
      @source_id = source_id
      @prompt_project = prompt_project
      @metadata = metadata
    end

    def call
      prompt_version = resolve_prompt_version
      LlmOutputMetric.find_or_create_by!(
        project: project,
        output_type: output_type,
        source_type: source_type,
        source_id: source_id
      ) do |metric|
        metric.account = project.account
        metric.prompt_slug = prompt_slug
        metric.prompt_version = prompt_version
        metric.scores = {}
        metric.metadata = metadata.merge("recorded_at" => Time.current.iso8601)
      end
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      # Race with a concurrent insert — return the winner's record.
      LlmOutputMetric.find_by(
        project: project,
        output_type: output_type,
        source_type: source_type,
        source_id: source_id
      ) || begin
        Rails.logger.warn(
          message: "llm_output_metrics.record_failed",
          output_type: output_type,
          source_type: source_type,
          source_id: source_id,
          error: e.message
        )
        nil
      end
    end

    private

    attr_reader :project, :output_type, :prompt_slug, :source_type, :source_id, :prompt_project, :metadata

    # Mirror the resolution logic in Prompts::Render.call so the recorded
    # prompt version matches the one that actually rendered the output.
    def resolve_prompt_version
      prompt = if prompt_project
        Prompt.resolve(prompt_slug, project: prompt_project)
      else
        Prompt.global.active.find_by(slug: prompt_slug)
      end
      prompt&.current_version
    end
  end
end
