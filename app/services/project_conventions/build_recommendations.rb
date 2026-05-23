# frozen_string_literal: true

module ProjectConventions
  class BuildRecommendations
    def self.call(...)
      new(...).call
    end

    def initialize(project:)
      @project = project
    end

    def call
      profile = ProjectConventions::Resolve.profile(project:)
      recommendations = build_recommendations(profile)
      sync_recommendations(recommendations)
    end

    private

    attr_reader :project

    def build_recommendations(profile)
      recommendations = profile[:conventions].flat_map do |_key, entry|
        recommendations_for_entry(entry)
      end.compact

      hook_guardrail = ProjectConventions::HookGuardrailStrategy.recommendation_for(profile:)
      recommendations << hook_guardrail if hook_guardrail
      recommendations
    end

    def recommendations_for_entry(entry)
      recs = []
      key = entry[:key]
      evidence = entry[:evidence] || {}
      detected_value = entry[:detected_value]
      confidence = entry[:confidence].to_f

      recs << commit_style_recommendation(key, evidence, detected_value, confidence) if key == "commit_style" && confidence >= 0.5
      recs << release_automation_recommendation(key, evidence, detected_value, confidence) if key == "release_automation" && confidence >= 0.5
      recs << dependency_format_recommendation(key, evidence, detected_value, confidence) if key == "issue_dependency_format" && confidence >= 0.5
      recs
    end

    def commit_style_recommendation(key, evidence, detected_value, confidence)
      commit_type = detected_value.is_a?(Hash) ? detected_value["type"] : nil
      return unless commit_type == "conventional_commits"

      paths = Array(evidence["paths"])
      signal_desc = paths.any? ? "detected from #{paths.join(', ')}" : "detected from repository analysis"

      {
        convention_key: key,
        action_type: "apply_in_paid",
        title: "Enable conventional commit enforcement",
        description: "Conventional commits #{signal_desc} (#{format("%.0f%%", confidence * 100)} confidence). Apply enforcement in Paid so agent commits follow the #{commit_type} style.",
        evidence: evidence.merge("confidence" => confidence, "detected_value" => detected_value),
        generated_at: Time.current
      }
    end

    def release_automation_recommendation(key, evidence, detected_value, confidence)
      return if detected_value.blank?

      paths = Array(evidence["paths"])
      signal_desc = paths.any? ? "detected from #{paths.join(', ')}" : "detected from repository analysis"

      {
        convention_key: key,
        action_type: "manual_review",
        title: "Review detected release automation",
        description: "Release automation #{signal_desc} (#{format("%.0f%%", confidence * 100)} confidence). Review the detected workflow manually; Paid does not apply release automation behavior from this recommendation yet.",
        evidence: evidence.merge("confidence" => confidence, "detected_value" => detected_value),
        generated_at: Time.current
      }
    end

    def dependency_format_recommendation(key, evidence, detected_value, confidence)
      return unless detected_value.is_a?(Hash) && detected_value["depends_on_prefix"].present?

      {
        convention_key: key,
        action_type: "apply_github_side",
        title: "Adopt explicit dependency wording templates",
        description: "Issue dependency wording detected (e.g. \"#{detected_value["depends_on_prefix"]} #123\"). Adopt this format in issue templates so Paid can parse dependency blocks reliably.",
        evidence: evidence.merge("confidence" => confidence, "detected_value" => detected_value),
        generated_at: Time.current
      }
    end

    def sync_recommendations(recommendations)
      existing_by_key_action = project.project_convention_recommendations
        .order(Arel.sql("CASE status WHEN 'pending' THEN 0 WHEN 'applied' THEN 1 ELSE 2 END"), generated_at: :desc, id: :desc)
        .to_a
        .each_with_object({}) do |rec, indexed|
          lookup_key = "#{rec.convention_key}:#{rec.action_type}"
          indexed[lookup_key] ||= rec
        end

      recommendations.each do |rec_attrs|
        lookup_key = "#{rec_attrs[:convention_key]}:#{rec_attrs[:action_type]}"
        existing = existing_by_key_action.delete(lookup_key)

        if existing
          sync_existing_recommendation(existing, rec_attrs)
        else
          project.project_convention_recommendations.create!(rec_attrs)
        end
      end

      existing_by_key_action.each_value.select(&:pending?).each do |stale|
        stale.dismiss!(dismissed_by: nil, reason: ProjectConventionRecommendation::AUTO_DISMISSAL_REASON)
      end
    end

    def sync_existing_recommendation(existing, rec_attrs)
      if existing.auto_dismissed?
        existing.reopen!(rec_attrs)
      else
        existing.update!(rec_attrs)
      end
    end
  end
end
