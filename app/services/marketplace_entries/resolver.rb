# frozen_string_literal: true

require "set"

module MarketplaceEntries
  class Resolver
    Result = Struct.new(:entry, :version, :source, :reason, keyword_init: true)

    attr_reader :project, :agent_run, :manual_entry_ids, :auto_attach_enabled

    def initialize(project:, agent_run:, manual_entry_ids: nil, auto_attach_enabled: false)
      @project = project
      @agent_run = agent_run
      @manual_entry_ids = Array(manual_entry_ids).filter_map { |id| Integer(id, exception: false) }.uniq
      @auto_attach_enabled = auto_attach_enabled
    end

    def self.call(...)
      new(...).call
    end

    def call
      selections = {}
      attach_automatic_entries!(selections)
      attach_team_default_entries!(selections)
      attach_manual_entries!(selections)
      selections.values
    end

    private

    def attach_automatic_entries!(selections)
      return unless auto_attach_enabled?

      automatic_compatible_entries.each do |entry|
        matching_rule = ordered_enabled_rules(entry).find do |rule|
          rule.mode == "automatic" && rule_matches?(rule, entry)
        end
        next unless matching_rule

        selections[entry.id] = Result.new(
          entry:,
          version: entry.current_version,
          source: "automatic",
          reason: matching_rule.rationale.presence || "Matched automatic marketplace rule"
        )
      end
    end

    def attach_team_default_entries!(selections)
      return unless auto_attach_enabled?

      compatible_entries.each do |entry|
        matching_rule = ordered_enabled_rules(entry).find do |rule|
          rule.mode == "team_default" && rule_matches?(rule, entry)
        end
        next unless matching_rule

        selections[entry.id] = Result.new(
          entry:,
          version: entry.current_version,
          source: "team_default",
          reason: matching_rule.rationale.presence || "Matched team default marketplace rule"
        )
      end
    end

    def attach_manual_entries!(selections)
      return if effective_manual_entry_ids.empty?

      compatible_entries.select { |entry| effective_manual_entry_ids.include?(entry.id) }.each do |entry|
        selections[entry.id] = Result.new(
          entry:,
          version: entry.current_version,
          source: "manual",
          reason: "Selected manually for this run"
        )
      end
    end

    def effective_manual_entry_ids
      return manual_entry_ids if manual_entry_ids.any?

      agent_run.agent_run_marketplace_entries.where(attachment_source: "manual").pluck(:marketplace_entry_id)
    end

    def candidate_entries
      @candidate_entries ||= MarketplaceEntry
        .includes(:current_version, :marketplace_entry_rules)
        .where(account: project.account, status: "active")
        .where.not(current_version_id: nil)
    end

    def ordered_enabled_rules(entry)
      entry.marketplace_entry_rules.select(&:enabled?).sort_by { |rule| [ rule.position, rule.id ] }
    end

    def compatible_entries
      @compatible_entries ||= candidate_entries.select { |entry| compatible_with_run?(entry.current_version) }
    end

    def automatic_compatible_entries
      @automatic_compatible_entries ||= begin
        opted_in_ids = persisted_opted_in_entry_ids
        compatible_entries.select { |entry| opted_in_ids.include?(entry.id) }
      end
    end

    def persisted_opted_in_entry_ids
      return Set.new unless project.respond_to?(:account_id) && project.account_id.present?

      # Agent runs do not currently persist the initiating user, so the durable
      # opt-in signal we can enforce today is account-level: an entry must have
      # been manually attached on a prior run in this account before automatic
      # rules may start attaching it.
      @persisted_opted_in_entry_ids ||= AgentRunMarketplaceEntry
        .joins(:agent_run)
        .where(agent_runs: { account_id: project.account_id })
        .where(attachment_source: "manual")
        .distinct
        .pluck(:marketplace_entry_id)
        .to_set
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

    def auto_attach_enabled?
      auto_attach_enabled
    end
  end
end
