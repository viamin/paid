# frozen_string_literal: true

module QualityRecovery
  # Given a diagnosis from QualityRecovery::Diagnose, suggests concrete recovery
  # actions: prompt rollback, model/agent type change, or configuration adjustment.
  #
  # @example
  #   suggestions = QualityRecovery::SuggestFixes.call(
  #     project: project,
  #     diagnosis: diagnosis
  #   )
  #   suggestions # => [{ action_type: "prompt_rollback", ... }]
  class SuggestFixes
    def self.call(...)
      new(...).call
    end

    def initialize(project:, diagnosis:)
      @project = project
      @diagnosis = diagnosis
    end

    def call
      return [] if diagnosis[:patterns].blank?

      suggestions = []

      diagnosis[:patterns].each do |pattern|
        case pattern[:type]
        when "prompt_version_regression"
          suggestions.concat(suggest_prompt_rollback(pattern))
        when "agent_type_failures"
          suggestions.concat(suggest_model_change(pattern))
        when "quality_score_decline"
          suggestions.concat(suggest_config_adjustment(pattern))
        when "high_failure_rate"
          suggestions.concat(suggest_for_high_failure_rate(pattern))
        when "anomaly_cluster"
          suggestions.concat(suggest_for_anomaly_cluster(pattern))
        end
      end

      suggestions << suggest_resume_with_monitoring if suggestions.any?
      suggestions.uniq { |s| [ s[:action_type], s[:parameters] ] }
    end

    private

    attr_reader :project, :diagnosis

    def suggest_prompt_rollback(pattern)
      version_id = pattern.dig(:details, :prompt_version_id)
      return [] unless version_id

      current_version = PromptVersion.find_by(id: version_id)
      return [] unless current_version

      previous_version = current_version.prompt.prompt_versions
        .where("version < ?", current_version.version)
        .order(version: :desc)
        .first

      return [] unless previous_version

      [ {
        action_type: "prompt_rollback",
        reason: "Prompt version #{current_version.version} has a #{format_percent(pattern.dig(:details, :failure_rate))} failure rate",
        parameters: {
          prompt_id: current_version.prompt_id,
          from_version_id: current_version.id,
          to_version_id: previous_version.id,
          to_version_number: previous_version.version
        },
        confidence: confidence_from_severity(pattern[:severity])
      } ]
    end

    def suggest_model_change(pattern)
      agent_type = pattern.dig(:details, :agent_type)
      return [] unless agent_type

      alternative_types = AgentRun::AGENT_TYPES - [ agent_type ]
      recently_successful = project.agent_runs
        .where(status: "completed", agent_type: alternative_types)
        .where(completed_at: 7.days.ago..)
        .group(:agent_type)
        .count

      return [] if recently_successful.empty?

      best_alternative = recently_successful.max_by { |_, count| count }&.first
      return [] unless best_alternative

      [ {
        action_type: "model_change",
        reason: "Agent type '#{agent_type}' has a #{format_percent(pattern.dig(:details, :failure_rate))} failure rate; '#{best_alternative}' has recent successes",
        parameters: {
          from_agent_type: agent_type,
          to_agent_type: best_alternative,
          recent_success_count: recently_successful[best_alternative]
        },
        confidence: confidence_from_severity(pattern[:severity])
      } ]
    end

    def suggest_config_adjustment(pattern)
      drop = pattern.dig(:details, :drop) || 0
      [ {
        action_type: "config_adjustment",
        reason: "Quality score dropped by #{(drop * 100).round(1)}% compared to previous runs",
        parameters: {
          adjustment_type: "review_settings",
          suggestions: build_config_suggestions(pattern)
        },
        confidence: confidence_from_severity(pattern[:severity])
      } ]
    end

    def suggest_for_high_failure_rate(pattern)
      suggestions = []
      statuses = pattern.dig(:details, :statuses) || {}

      if statuses["timeout"].to_i > 0
        suggestions << {
          action_type: "config_adjustment",
          reason: "#{statuses['timeout']} runs timed out; consider increasing timeout",
          parameters: {
            adjustment_type: "timeout_increase",
            current_timeouts: statuses["timeout"]
          },
          confidence: "medium"
        }
      end

      if statuses["rate_limited"].to_i > 0
        suggestions << {
          action_type: "model_change",
          reason: "#{statuses['rate_limited']} runs were rate-limited; consider switching provider",
          parameters: {
            adjustment_type: "provider_switch",
            rate_limited_count: statuses["rate_limited"]
          },
          confidence: "medium"
        }
      end

      suggestions
    end

    def suggest_for_anomaly_cluster(pattern)
      metric_name = pattern.dig(:details, :metric_name)
      return [] unless metric_name

      [ {
        action_type: "config_adjustment",
        reason: "Repeated anomalies in #{metric_name} (#{pattern.dig(:details, :anomaly_count)} in 24h)",
        parameters: {
          adjustment_type: "anomaly_investigation",
          metric_name: metric_name,
          anomaly_count: pattern.dig(:details, :anomaly_count)
        },
        confidence: confidence_from_severity(pattern[:severity])
      } ]
    end

    def suggest_resume_with_monitoring
      {
        action_type: "resume_with_monitoring",
        reason: "Run one agent at a time until quality stabilizes after applying fixes",
        parameters: {
          max_concurrent: 1,
          evaluation_window: 5
        },
        confidence: "high"
      }
    end

    def build_config_suggestions(pattern)
      suggestions = []
      recent_avg = pattern.dig(:details, :recent_average) || 0

      if recent_avg < 0.5
        suggestions << "Consider reducing task complexity by breaking issues into smaller units"
        suggestions << "Review and tighten prompt instructions"
      end

      suggestions << "Enable stricter review settings to catch quality issues earlier"
      suggestions
    end

    def confidence_from_severity(severity)
      case severity
      when "critical" then "high"
      when "warning" then "medium"
      else "low"
      end
    end

    def format_percent(value)
      return "0%" unless value

      "#{(value * 100).round(1)}%"
    end
  end
end
