# frozen_string_literal: true

module AgentRunPatterns
  class Notify
    NOTIFICATION_SOURCE = "agent_run_pattern_detector"

    def self.call(...)
      new(...).call
    end

    def initialize(account:, patterns:, diagnoses:, decisions:)
      @account = account
      @patterns = patterns
      @diagnoses = diagnoses
      @decisions = decisions
    end

    def call
      publish_in_app_notification unless patterns.empty?
      resolve_cleared_patterns
    end

    private

    attr_reader :account, :patterns, :diagnoses, :decisions

    def ordered_patterns
      @ordered_patterns ||= patterns.sort_by do |pattern|
        [
          -severity_rank(pattern),
          pattern.goal.to_s,
          pattern.type.to_s,
          pattern.details[:error_pattern].to_s
        ]
      end
    end

    def publish_in_app_notification
      worst = worst_pattern
      diagnosis = diagnosis_for(worst)
      decision = decision_for(worst)

      Notifications::Publish.call(
        account: account,
        source: NOTIFICATION_SOURCE,
        subject: account,
        severity: notification_severity(worst),
        title: notification_title(worst, diagnosis),
        description: notification_description(worst, diagnosis, decision),
        metadata: build_metadata(decision),
        action_url: decision ? "/remediation_decisions/#{decision.id}" : "/dashboard",
        nav_section: "dashboard"
      )
    end

    def resolve_cleared_patterns
      active_goals = patterns.map(&:goal).to_set

      Notification.where(
        account: account,
        source: NOTIFICATION_SOURCE
      ).active.each do |notification|
        notification_goals = tracked_goals(notification)
        next if notification_goals.empty?
        next if notification_goals.any? { |g| active_goals.include?(g) }

        Notifications::Resolve.call(
          account: account,
          source: NOTIFICATION_SOURCE,
          subject: notification.subject,
          user: notification.user
        )
      end
    end

    def worst_pattern
      ordered_patterns.first
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

    def notification_description(worst, diagnosis, decision)
      parts = []
      parts << "Detected failure patterns across #{ordered_patterns.size} goal type(s):"
      parts << ""

      ordered_patterns.each do |pattern|
        parts << pattern_summary(pattern)
      end

      if diagnosis
        parts << ""
        parts << "Root cause: #{diagnosis.root_cause}"
        parts << action_summary(decision, diagnosis)

        evidence_lines = evidence_lines_for(worst, diagnosis)
        if evidence_lines.any?
          parts << "Why:"
          parts.concat(evidence_lines)
        end
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
        "#{goal}: #{details[:failure_count]}/#{details[:total_count]} failures (#{(details[:failure_rate] * 100).round}% rate)"
      when :error_cluster
        "#{goal}: #{details[:occurrence_count]} failures share similar error: \"#{details[:error_pattern].truncate(80)}\""
      else
        "#{goal}: failure pattern detected"
      end
    end

    def build_metadata(decision)
      {
        pattern_count: ordered_patterns.size,
        pattern_types: ordered_patterns.map { |p| "#{p.goal}:#{p.type}" },
        goals: ordered_patterns.map(&:goal).uniq,
        worst_goal: worst_pattern.goal,
        diagnosed_root_cause: diagnosis_for(worst_pattern)&.root_cause,
        remediation_decision_id: decision&.id,
        remediation_status: decision&.status,
        revert_url: decision&.revertable? ? "/remediation_decisions/#{decision.id}/revert" : nil
      }
    end

    def severity_rank(pattern)
      pattern.severity == :error ? 1 : 0
    end

    def tracked_goals(notification)
      goals = metadata_value(notification, :goals)
      return goals if goals

      metadata_value(notification, :worst_goal) || []
    end

    def metadata_value(notification, key)
      metadata = notification.metadata
      Array(metadata&.dig(key.to_s) || metadata&.dig(key)).presence
    end

    def diagnosis_for(pattern)
      diagnoses[fingerprint(pattern)]
    end

    def decision_for(pattern)
      decisions[fingerprint(pattern)]
    end

    def fingerprint(pattern)
      pattern.details[:fingerprint].to_s
    end

    def human_action(diagnosis)
      target = diagnosis.action_target.deep_stringify_keys
      label = diagnosis.proposed_action.humanize
      return label if target["type"] == "account"
      return "#{label} (runner ##{target["id"]})" if target["type"] == "runner"
      return "#{label} (project ##{target["id"]})" if target["type"] == "project"

      "#{label} (runner ##{target["id"]}, field #{target["field_name"]})"
    end

    def action_summary(decision, diagnosis)
      if decision&.applied?
        "Auto-applied action: #{human_action(diagnosis)}"
      else
        "Proposed action: #{human_action(diagnosis)}"
      end
    end

    def evidence_lines_for(pattern, diagnosis)
      bundle = AgentRunPatterns::EvidenceBundle.from_payload(pattern.details[:evidence_bundle])

      diagnosis.evidence_pointers.filter_map do |pointer|
        snippet = bundle.text_for_pointer(pointer)
        next "- #{pointer}" if snippet.blank?

        "- #{pointer}: #{snippet.tr("\n", " ").truncate(120)}"
      end
    end
  end
end
