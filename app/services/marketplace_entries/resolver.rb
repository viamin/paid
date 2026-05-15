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
      attach_automatic_entries!(selections)
      attach_team_default_entries!(selections)
      attach_manual_entries!(selections)
      selections.values
    end

    private

    def attach_automatic_entries!(selections)
      return unless auto_attach_enabled?

      selected_compatible_entries.each do |entry|
        next if selections.key?(entry.id)

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
      return unless auto_attach_enabled? || account_auto_attach_required?

      team_default_compatible_entries.each do |entry|
        next if selections.key?(entry.id)

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

      compatible_entries.each do |entry|
        next unless effective_manual_entry_ids.include?(entry.id)
        next if selections.key?(entry.id)

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

    def selected_compatible_entries
      @selected_compatible_entries ||= compatible_entries.select { |entry| effective_manual_entry_ids.include?(entry.id) }
    end

    def team_default_compatible_entries
      @team_default_compatible_entries ||= if account_auto_attach_required?
        compatible_entries
      else
        selected_compatible_entries
      end
    end

    def prefiltered_candidate_entries
      entries = candidate_entries
      return entries unless entries.is_a?(ActiveRecord::Relation)

      relation = filter_relation_by_constraint(entries, "provider_keys", provider_key)
      relation = filter_relation_by_constraint(relation, "agent_types", agent_run.agent_type)
      relation = filter_relation_by_constraint(relation, "goals", agent_run.goal)
      relation = filter_relation_by_constraint(relation, "project_ids", project.id)
      filter_relation_by_constraint(relation, "repository_full_names", project.full_name)
    end

    def filter_relation_by_constraint(relation, constraint_key, actual_value)
      return relation if actual_value.blank?

      json_path = "marketplace_entry_versions.compatibility_constraints -> '#{constraint_key}'"
      candidate_values = jsonb_candidate_values(actual_value)
      predicates = candidate_values.map.with_index do |_value, index|
        "#{json_path} @> :value_#{index}::jsonb"
      end

      relation.where(
        <<~SQL.squish,
          #{json_path} IS NULL
          OR #{json_path} = '[]'::jsonb
          OR (#{predicates.join(' OR ')})
        SQL
        **candidate_values.each_with_index.to_h { |value, index| [ :"value_#{index}", [ value ].to_json ] }
      )
    end

    def jsonb_candidate_values(actual_value)
      values = [ actual_value.to_s ]
      values << actual_value if actual_value.is_a?(Numeric)
      values.uniq
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

    def account_auto_attach_required?
      account_auto_attach_required
    end
  end
end
