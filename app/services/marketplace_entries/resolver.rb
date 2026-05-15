# frozen_string_literal: true

module MarketplaceEntries
  class Resolver
    Result = Struct.new(:entry, :version, :source, :reason, keyword_init: true)

    attr_reader :project, :agent_run, :manual_entry_ids, :auto_attach_enabled, :account_auto_attach_required

    def initialize(project:, agent_run:, manual_entry_ids: nil, auto_attach_enabled: false, account_auto_attach_required: false)
      @project = project
      @agent_run = agent_run
      @manual_entry_ids = Array(manual_entry_ids).filter_map { |id| Integer(id, exception: false) }.uniq
      @auto_attach_enabled = auto_attach_enabled
      @account_auto_attach_required = account_auto_attach_required
    end

    def self.call(...)
      new(...).call
    end

    def call
      selections = {}
      attach_rule_based_entries!(selections, mode: "automatic", source: "automatic")
      attach_rule_based_entries!(selections, mode: "team_default", source: "team_default")
      attach_manual_entries!(selections)
      selections.values
    end

    private

    def attach_rule_based_entries!(selections, mode:, source:)
      return unless auto_attach_enabled? || account_auto_attach_required?

      compatible_entries.each do |entry|
        next if selections.key?(entry.id)

        matching_rule = ordered_enabled_rules(entry).find do |rule|
          rule.mode == mode && rule_matches?(rule, entry)
        end
        next unless matching_rule

        selections[entry.id] = Result.new(
          entry:,
          version: entry.current_version,
          source: source,
          reason: matching_rule.rationale.presence || default_rule_reason(source)
        )
      end
    end

    def attach_manual_entries!(selections)
      return if effective_manual_entry_ids.empty?

      compatible_entries.each do |entry|
        next unless effective_manual_entry_ids.include?(entry.id)

        selections[entry.id] = Result.new(
          entry:,
          version: entry.current_version,
          source: "manual",
          reason: "Selected manually for this run"
        )
      end
    end

    def effective_manual_entry_ids
      @effective_manual_entry_ids ||= if manual_entry_ids.any?
        manual_entry_ids
      else
        agent_run.agent_run_marketplace_entries.where(attachment_source: "manual").pluck(:marketplace_entry_id)
      end
    end

    def candidate_entries
      @candidate_entries ||= MarketplaceEntry
        .joins(:current_version)
        .includes(:current_version, :marketplace_entry_rules)
        .where(account: project.account, status: "active")
        .where.not(current_version_id: nil)
    end

    def ordered_enabled_rules(entry)
      entry.marketplace_entry_rules.select(&:enabled?).sort_by { |rule| [ rule.position, rule.id ] }
    end

    def compatible_entries
      @compatible_entries ||= prefiltered_candidate_entries.select { |entry| compatible_with_run?(entry.current_version) }
    end

    def prefiltered_candidate_entries
      candidate_entries.to_a
    end

    def compatible_with_run?(version)
      constraints = version.compatibility_constraints
      match_constraint(constraints["provider_keys"], provider_key) &&
        match_constraint(constraints["agent_types"], agent_run.agent_type) &&
        match_constraint(constraints["goals"], agent_run.goal) &&
        match_constraint(constraints["project_ids"], project.id) &&
        match_constraint(constraints["repository_full_names"], project.full_name)
    end

    def rule_matches?(rule, _entry)
      conditions = rule.conditions
      match_constraint(conditions["provider_keys"], provider_key) &&
        match_constraint(conditions["agent_types"], agent_run.agent_type) &&
        match_constraint(conditions["goals"], agent_run.goal) &&
        match_constraint(conditions["project_ids"], project.id) &&
        match_constraint(conditions["repository_full_names"], project.full_name) &&
        match_text_constraint(conditions["task_text_includes_any"])
    end

    def match_constraint(allowed_values, actual_value)
      values = Array(allowed_values).reject(&:blank?)
      return true if values.empty?

      values.map(&:to_s).include?(actual_value.to_s)
    end

    def match_text_constraint(patterns)
      candidates = Array(patterns).map(&:to_s).reject(&:blank?)
      return true if candidates.empty?

      haystack = [
        agent_run.custom_prompt,
        agent_run.issue&.title,
        agent_run.issue&.body
      ].compact.join("\n").downcase
      return false if haystack.blank?

      candidates.any? { |pattern| haystack.include?(pattern.downcase) }
    end

    def provider_key
      @provider_key ||= agent_run.provider&.provider_key || ProviderSupport.provider_key_for_agent_type(agent_run.agent_type)
    end

    def default_rule_reason(source)
      "Matched #{source.tr('_', ' ')} marketplace rule"
    end

    def auto_attach_enabled?
      auto_attach_enabled
    end

    def account_auto_attach_required?
      account_auto_attach_required
    end
  end
end
