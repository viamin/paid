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

    def initialize(project:, output_type:, prompt_slug:, source_type:, source_id:, metadata: {})
      @project = project
      @output_type = output_type
      @prompt_slug = prompt_slug
      @source_type = source_type
      @source_id = source_id
      @metadata = metadata
    end

    def call
      prompt_version = resolve_prompt_version
      LlmOutputMetric.create!(
        project: project,
        account: project.account,
        output_type: output_type,
        prompt_slug: prompt_slug,
        source_type: source_type,
        source_id: source_id,
        prompt_version: prompt_version,
        scores: {},
        metadata: metadata.merge("recorded_at" => Time.current.iso8601)
      )
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn(
        message: "llm_output_metrics.record_failed",
        output_type: output_type,
        source_type: source_type,
        source_id: source_id,
        error: e.message
      )
      nil
    end

    private

    attr_reader :project, :output_type, :prompt_slug, :source_type, :source_id, :metadata

    def resolve_prompt_version
      prompt = Prompt.resolve(prompt_slug, project: project)
      prompt ||= Prompt.global.active.find_by(slug: prompt_slug)
      prompt&.current_version
    end
  end
end
