# frozen_string_literal: true

module Models
  class MetaAgentSelector
    MODEL = "claude-haiku-4-5-20251001"
    TIMEOUT = 15
    MAX_BODY_LENGTH = 2000

    def self.call(...)
      new(...).call
    end

    def initialize(agent_run:)
      @agent_run = agent_run
    end

    def call
      candidates = available_candidates
      return nil if candidates.empty?

      response = request_selection(candidates)
      return nil unless response

      selected = candidates.find { |m| m.model_id == response[:model_id] }
      return nil unless selected

      {
        model: selected,
        selector_type: "meta_agent",
        reasoning: response[:reasoning],
        candidates: candidates.map { |m| { model_id: m.model_id, score: m.capability_score.to_f } },
        complexity_score: response[:complexity_score]
      }
    rescue AgentHarness::Error, JSON::ParserError => e
      Rails.logger.warn(
        message: "model_selection.meta_agent_failed",
        agent_run_id: agent_run.id,
        error_class: e.class.name,
        error: e.message
      )
      nil
    end

    private

    attr_reader :agent_run

    def available_candidates
      scope = LlmModel.active

      excluded = agent_run.project.model_preferences["excluded_model_ids"]
      scope = scope.where.not(model_id: excluded) if excluded.present?

      scope.order(Arel.sql("capability_score DESC NULLS LAST")).to_a
    end

    def request_selection(candidates)
      response = AgentHarness.send_message(
        build_prompt(candidates),
        provider: :claude,
        model: MODEL,
        timeout: TIMEOUT
      )
      return nil unless response.success?

      parse_response(response.output, candidates)
    end

    def parse_response(output, candidates)
      return nil if output.blank?

      json = extract_json(output)
      parsed = JSON.parse(json)
      model_id = parsed["model"]
      reasoning = parsed["reasoning"].to_s.truncate(500)
      complexity = parsed["complexity_score"]

      return nil unless candidates.any? { |m| m.model_id == model_id }

      complexity_float = complexity.present? ? Float(complexity).clamp(1.0, 10.0) : nil

      { model_id: model_id, reasoning: reasoning, complexity_score: complexity_float }
    rescue ArgumentError
      nil
    end

    def extract_json(text)
      if (match = text.match(/\{[^{}]*\}/m))
        match[0]
      else
        text
      end
    end

    def build_prompt(candidates)
      issue = agent_run.issue
      project = agent_run.project

      <<~PROMPT.strip
        Select the best LLM model for this development task.

        ## Task
        Goal: #{agent_run.goal}
        #{task_details(issue)}

        ## Project
        Repository: #{project.full_name}
        #{budget_context(project)}

        ## Available Models
        #{format_candidates(candidates)}

        ## Instructions
        Consider task complexity, reasoning requirements, cost-effectiveness, and any budget constraints.
        Simple tasks (typo fixes, small edits) should use cheaper models.
        Complex tasks (architecture, multi-file refactors) need the most capable models.
        If budget is limited, prefer cost-effective models unless the task clearly requires high capability.

        Respond with ONLY a JSON object:
        {"model": "model-id", "reasoning": "brief explanation", "complexity_score": 5.0}

        complexity_score must be a number from 1.0 (trivial) to 10.0 (extremely complex).
      PROMPT
    end

    def task_details(issue)
      return "No linked issue" unless issue

      body = issue.body.to_s.truncate(MAX_BODY_LENGTH, omission: "...")
      "Title: #{issue.title}\nDescription: #{body}"
    end

    def budget_context(project)
      budgets = project.cost_budgets.select { |b| b.limit_cents.positive? }
      return "" if budgets.empty?

      lines = budgets.map do |b|
        "#{b.budget_type} budget: $#{"%.2f" % (b.remaining_cents / 100.0)} remaining of $#{"%.2f" % (b.limit_cents / 100.0)}"
      end
      "Budget: #{lines.join(", ")}"
    end

    def format_candidates(candidates)
      candidates.map do |m|
        cost_info = if m.input_cost_per_million && m.output_cost_per_million
          "$#{m.input_cost_per_million}/M in, $#{m.output_cost_per_million}/M out"
        else
          "pricing unknown"
        end

        "- #{m.model_id}: #{m.display_name}, capability=#{m.capability_score}, #{cost_info}"
      end.join("\n")
    end
  end
end
