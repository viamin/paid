# frozen_string_literal: true

module Models
  # @spec AGENT-HARNESS-003, MODEL-SELECTION-002
  class MetaAgentSelector
    include RunnerTierLookup

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
      initial_complexity = RulesBasedSelector.new(agent_run: agent_run).estimate_complexity
      initial_tier = TierForComplexity.call(complexity: initial_complexity, agent_run: agent_run)

      candidates = available_candidates(tier: initial_tier)
      return nil if candidates.empty?

      # When the candidate pool contains a single entry — whether from a runner
      # tier pin or a global pool with one active model — skip the LLM round-trip.
      if candidates.size == 1
        only = candidates.first
        return {
          model: only,
          selector_type: "meta_agent",
          tier: initial_tier,
          reasoning: "Single candidate in pool; LLM selection skipped",
          candidates: [ only ],
          complexity_score: initial_complexity
        }
      end

      response = request_selection(candidates)
      return nil unless response

      selected = candidates.find { |m| m.model_id == response[:model_id] }
      return nil unless selected

      {
        model: selected,
        selector_type: "meta_agent",
        # Record the tier the candidate pool was drawn from so analytics on
        # `model_selection.tier` stay consistent with the model that was
        # actually selectable. The LLM's complexity_score is preserved
        # separately on the selection record.
        tier: initial_tier,
        reasoning: response[:reasoning],
        candidates: candidates,
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

    def available_candidates(tier: nil)
      scope = compatible_model_scope(LlmModel.active)

      excluded = agent_run.project.model_preferences["excluded_model_ids"]
      scope = scope.where.not(model_id: excluded) if excluded.present?

      # Prefer the runner's explicitly configured tier model when available
      runner_model = runner_tier_model(tier)
      if runner_model && !excluded_model?(runner_model, excluded)
        return [ runner_model ]
      end

      if tier
        tier_candidates = scope.by_tier(tier).order(Arel.sql("capability_score DESC NULLS LAST")).to_a
        # Fall back to the full pool when the tier is empty so the meta-agent
        # still has something to choose from (e.g. before tiers are seeded).
        return tier_candidates if tier_candidates.any?
      end

      scope.order(Arel.sql("capability_score DESC NULLS LAST")).to_a
    end

    def request_selection(candidates)
      response = AgentHarness.send_message(
        build_prompt(candidates),
        provider: :claude,
        model: MODEL,
        timeout: TIMEOUT,
        tools: :none,
        **Llm::TextMode.options
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
    rescue ArgumentError, TypeError
      nil
    end

    def extract_json(text)
      return text if text.blank?

      # Prefer explicitly fenced ```json code blocks
      if (code_block = text[/```json\s*(.*?)```/m, 1])
        return code_block.strip
      end

      # Fallback: any fenced code block that looks like a JSON object
      if (generic_block = text[/```\s*(\{.*?\})\s*```/m, 1])
        return generic_block.strip
      end

      # If the entire text is valid JSON, use it as-is
      begin
        JSON.parse(text)
        return text
      rescue JSON::ParserError
        # ignore and try balanced-brace extraction
      end

      # Balanced-brace extraction starting from the first '{'
      extract_balanced_json(text)
    end

    def extract_balanced_json(text)
      start_index = text.index("{")
      return text unless start_index

      depth = 0
      in_string = false
      escape_next = false

      (start_index...text.length).each do |i|
        ch = text[i]

        if in_string
          if escape_next
            escape_next = false
          elsif ch == "\\"
            escape_next = true
          elsif ch == '"'
            in_string = false
          end
        elsif ch == '"'
          in_string = true
        elsif ch == "{"
          depth += 1
        elsif ch == "}"
          depth -= 1 if depth > 0
          return text[start_index..i] if depth == 0
        end
      end

      text
    end

    PROMPT_SLUG = "planning.model_selection"

    # Fallback used only if the seeded prompt is missing or deactivated.
    # The active template lives in db/seeds/prompts.rb under PROMPT_SLUG.
    FALLBACK_PROMPT = <<~PROMPT
      Select the best LLM model for this development task.

      ## Task
      Goal: {{goal}}
      {{task_details}}

      ## Project
      Repository: {{repository}}
      {{budget_context}}

      ## Available Models
      {{candidates}}

      ## Instructions
      Consider task complexity, reasoning requirements, cost-effectiveness, and any budget constraints.
      Simple tasks (typo fixes, small edits) should use cheaper models.
      Complex tasks (architecture, multi-file refactors) need the most capable models.
      If budget is limited, prefer cost-effective models unless the task clearly requires high capability.

      Respond with ONLY a JSON object:
      {"model": "model-id", "reasoning": "brief explanation", "complexity_score": 5.0}

      complexity_score must be a number from 1.0 (trivial) to 10.0 (extremely complex).
    PROMPT

    def build_prompt(candidates)
      issue = agent_run.issue
      project = agent_run.project

      vars = {
        goal: agent_run.goal,
        task_details: task_details(issue),
        repository: project.full_name,
        budget_context: budget_context(project),
        candidates: format_candidates(candidates)
      }

      Prompts::Render.call(
        slug: PROMPT_SLUG,
        project: project,
        variables: vars,
        fallback: -> { Prompts::Render.interpolate(FALLBACK_PROMPT, vars) }
      ).strip
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
