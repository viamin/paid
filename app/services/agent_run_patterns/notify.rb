# frozen_string_literal: true

module AgentRunPatterns
  class Notify
    NOTIFICATION_SOURCE = "agent_run_pattern_detector"

    def self.call(...)
      new(...).call
    end

    def initialize(account:, patterns:, diagnoses:)
      @account = account
      @patterns = patterns
      @diagnoses = diagnoses
    end

    def call
      return if patterns.empty?

      publish_in_app_notification
      resolve_cleared_patterns
    end

    private

    attr_reader :account, :patterns, :diagnoses

    def publish_in_app_notification
      worst = worst_pattern
      diagnosis = diagnoses[worst.goal]

      Notifications::Publish.call(
        account: account,
        source: NOTIFICATION_SOURCE,
        subject: account,
        severity: notification_severity(worst),
        title: notification_title(worst, diagnosis),
        description: notification_description(worst, diagnosis),
        metadata: build_metadata,
        action_url: "/dashboard",
        nav_section: "dashboard"
      )
    end

    def resolve_cleared_patterns
      active_goals = patterns.map(&:goal).to_set

      Notification.where(
        account: account,
        source: NOTIFICATION_SOURCE
      ).active.each do |notification|
        notification_goals = Array(notification.metadata&.dig("goals"))
        next if notification_goals.any? { |g| active_goals.include?(g) }

        Notifications::Resolve.call(
          account: account,
          source: NOTIFICATION_SOURCE,
          subject: account
        )
      end
    end

    def worst_pattern
      patterns.max_by { |p| p.severity == :error ? 1 : 0 }
    end

    def notification_severity(pattern)
      pattern.severity == :error ? :error : :warning
    end

    def notification_title(pattern, diagnosis)
      goal = pattern.goal.humanize
      count = pattern.details[:streak_length] || pattern.details[:failure_count] || pattern.details[:occurrence_count] || 0
      root_cause = diagnosis&.root_cause || "Unknown"

      "#{goal} failures detected (#{count} failures) — #{root_cause}"
    end

    def notification_description(worst, diagnosis)
      parts = []
      parts << "Detected failure patterns across #{patterns.size} goal type(s):"
      parts << ""

      patterns.each do |pattern|
        parts << pattern_summary(pattern)
      end

      if diagnosis
        parts << ""
        parts << "Root cause: #{diagnosis.root_cause}"
        parts << "Remediation: #{diagnosis.remediation}"
      end

      parts.join("\n")
    end

    def pattern_summary(pattern)
      goal = pattern.goal.humanize
      details = pattern.details

      case pattern.type
      when :failure_streak
        "#{goal}: #{details[:streak_length]} consecutive failures (#{(details[:failure_rate] * 100).round}% of #{details[:total_runs]} runs)"
      when :high_failure_rate
        "#{goal}: #{details[:failure_count]}/#{details[:total_count]} failures (#{(details[:failure_rate] * 100).round(0)}% rate)"
      when :error_cluster
        "#{goal}: #{details[:occurrence_count]} failures share similar error: \"#{details[:error_pattern].truncate(80)}\""
      else
        "#{goal}: failure pattern detected"
      end
    end

    def build_metadata
      {
        pattern_count: patterns.size,
        pattern_types: patterns.map { |p| "#{p.goal}:#{p.type}" },
        goals: patterns.map(&:goal).uniq,
        worst_goal: worst_pattern.goal,
        diagnosed_root_cause: diagnoses.values.map(&:root_cause).compact.first
      }
    end
  end
end
