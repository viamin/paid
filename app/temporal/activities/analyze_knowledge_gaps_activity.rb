# frozen_string_literal: true

module Activities
  # Analyzes sampled enhance_issue runs via LLM to identify knowledge gaps,
  # collector recommendations, and effectiveness insights.
  #
  # Returns structured recommendations for the RecordKnowledgeRecommendationsActivity.
  class AnalyzeKnowledgeGapsActivity < BaseActivity
    activity_name "AnalyzeKnowledgeGaps"

    DEFAULT_MODEL = "claude-sonnet-4-6"
    LLM_TIMEOUT = 120
    COLLECTOR_TYPES = %w[route symbol dependency language_stat project_structure api_endpoint].freeze

    def execute(input)
      project_id = input[:project_id]
      sampled_runs = input[:sampled_runs]
      artifact_usage = input[:artifact_usage]

      project = Project.find(project_id)
      prompt = build_prompt(project, sampled_runs, artifact_usage)
      response = with_periodic_heartbeat("analyze_knowledge_gaps", project_id: project_id, model: DEFAULT_MODEL) do
        AgentHarness.send_message(
          prompt,
          provider: :claude,
          model: DEFAULT_MODEL,
          timeout: LLM_TIMEOUT,
          tools: :none,
          dangerous_mode: false,
          **Llm::TextMode.options
        )
      end

      parsed = parse_response(response)

      {
        project_id: project_id,
        recommendations: parsed
      }
    rescue AgentHarness::Error => e
      logger.error(
        message: "knowledge_evolution.llm_analysis_failed",
        project_id: input[:project_id],
        error_class: e.class.name,
        error: e.message
      )
      { project_id: input[:project_id], recommendations: [] }
    end

    private

    def build_prompt(project, sampled_runs, artifact_usage)
      <<~PROMPT
        You are analyzing a software project's knowledge base effectiveness.
        Your goal is to identify gaps in the knowledge collection system and
        recommend improvements.

        ## Project
        #{project.full_name}

        ## Existing Collector Types
        #{COLLECTOR_TYPES.join(", ")}

        ## Recent Enhance-Issue Run Data
        #{format_runs(sampled_runs)}

        ## Artifact Usage Statistics
        #{format_artifact_usage(artifact_usage)}

        ## Instructions
        Analyze the data above and identify:
        1. Knowledge gaps: questions that could have been answered with better knowledge collection
        2. Collector recommendations: new collector types that would fill gaps
        3. Collector effectiveness: existing collectors whose data is rarely useful
        4. Collector overlap: collectors producing redundant information

        Respond with ONLY valid JSON (no markdown fences):
        {
          "recommendations": [
            {
              "recommendation_type": "add_collector|remove_collector|improve_collector|knowledge_gap",
              "collector_type": "type_name",
              "priority": "low|medium|high|critical",
              "description": "What this recommendation addresses",
              "evidence": {
                "gap_frequency": 0,
                "example_questions": [],
                "would_fill_gaps": []
              }
            }
          ]
        }

        Only include actionable recommendations backed by evidence from the data.
        Return an empty recommendations array if no clear gaps are found.
      PROMPT
    end

    def format_runs(runs)
      return "No runs available." if runs.blank?

      runs.map do |run|
        parts = []
        parts << "- Run ##{run[:agent_run_id]}: #{run[:issue_title]}"
        parts << "  Questions: #{run[:questions_asked].join('; ')}" if run[:questions_asked].present?
        parts << "  Knowledge available: #{run[:knowledge_available]}" if run[:knowledge_available].present?
        parts << "  Sufficient context: #{run[:sufficient_context]}"
        parts << "  User responded: #{run[:user_responded]}" unless run[:user_responded].nil?
        parts << "  Outcome: #{run[:run_outcome]}" if run[:run_outcome].present?
        parts.join("\n")
      end.join("\n")
    end

    def format_artifact_usage(artifact_usage)
      return "No usage data available." if artifact_usage.blank?

      artifact_usage.map do |type, data|
        "- #{type}: #{data[:total_runs]} runs, #{data[:success_rate]}% success rate"
      end.join("\n")
    end

    def parse_response(response)
      output = response.respond_to?(:output) ? response.output.to_s : response.to_s
      parsed = JSON.parse(strip_json_fence(output), symbolize_names: true)
      Array(parsed[:recommendations]).map do |rec|
        rec.slice(:recommendation_type, :collector_type, :priority, :description, :evidence)
      end
    rescue JSON::ParserError => e
      logger.warn(
        message: "knowledge_evolution.parse_failed",
        error: e.message
      )
      []
    end

    def strip_json_fence(output)
      output.gsub(/\A```(?:json)?\s*/, "").gsub(/\s*```\z/, "").strip
    end
  end
end
