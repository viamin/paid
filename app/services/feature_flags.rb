# frozen_string_literal: true

class FeatureFlags
  Definition = Data.define(:name, :owner, :intent, :rollout_plan, :cleanup_criteria)

  UnknownFlagError = Class.new(ArgumentError)
  InvalidActorError = Class.new(ArgumentError)
  InvalidPercentageError = Class.new(ArgumentError)

  DEFINITIONS = {
    explicit_pr_automation_decisions: Definition.new(
      name: :explicit_pr_automation_decisions,
      owner: "infrastructure",
      intent: "Stage the PR automation decision refactor for the #1077 bug class behind an explicit gate.",
      rollout_plan: "Enable per project/repo during validation, monitor the new decision path, then promote to the default rollout.",
      cleanup_criteria: "Remove after the explicit-decision path is the only implementation and the legacy branch is deleted."
    ),
    focused_agent_runs: Definition.new(
      name: :focused_agent_runs,
      owner: "agent-runs",
      intent: "Stage focused agent runs so PR follow-ups can target a single highest-priority problem instead of a blended prompt.",
      rollout_plan: "Enable per project during validation of focus resolution and prompt plumbing, then expand once follow-up prompt scoping lands.",
      cleanup_criteria: "Remove after focused agent runs are the default behavior and the general-only fallback path is deleted."
    )
  }.freeze

  class << self
    def definitions
      DEFINITIONS.values
    end

    def definition(flag_name)
      DEFINITIONS.fetch(flag_name.to_sym)
    rescue KeyError
      raise UnknownFlagError, "Unknown feature flag: #{flag_name}"
    end

    def enabled?(flag_name, project: nil, actor: nil)
      tenant_value = tenant_override(flag_name, project:)
      return tenant_value unless tenant_value.nil?

      resolved_actor = resolve_actor(project:, actor:)
      return feature(flag_name).enabled? unless resolved_actor

      feature(flag_name).enabled?(resolved_actor)
    end

    def enable!(flag_name, project: nil, actor: nil)
      resolved_actor = resolve_actor(project:, actor:)
      return feature(flag_name).enable unless resolved_actor

      feature(flag_name).enable(resolved_actor)
    end

    def disable!(flag_name, project: nil, actor: nil)
      resolved_actor = resolve_actor(project:, actor:)

      unless resolved_actor
        # Flipper's boolean-gate disable already calls clear(feature), which
        # removes all gates (actor, group, percentage, etc.), so a global
        # disable is a complete rollback — no stale actor gates survive.
        return feature(flag_name).disable
      end

      feature(flag_name).disable(resolved_actor)
    end

    def enable_percentage_of_actors(flag_name, percentage)
      update_percentage_gate(feature(flag_name), :actors, percentage)
    end

    def disable_percentage_of_actors(flag_name)
      feature(flag_name).disable_percentage_of_actors
    end

    def enable_percentage_of_time(flag_name, percentage)
      update_percentage_gate(feature(flag_name), :time, percentage)
    end

    def disable_percentage_of_time(flag_name)
      feature(flag_name).disable_percentage_of_time
    end

    def rollout_status(flag_name)
      flipper_feature = feature(flag_name)

      {
        boolean: flipper_feature.boolean_value,
        percentage_of_actors: flipper_feature.percentage_of_actors_value,
        percentage_of_time: flipper_feature.percentage_of_time_value,
        actors: flipper_feature.actors_value.to_a.sort,
        groups: flipper_feature.groups_value.to_a.sort
      }
    end

    def snapshot(project: nil, actor: nil)
      DEFINITIONS.keys.index_with do |flag_name|
        enabled?(flag_name, project:, actor:)
      end
    end

    def explicit_pr_automation_decisions?(project: nil)
      enabled?(:explicit_pr_automation_decisions, project:)
    end

    def focused_agent_runs?(project: nil)
      enabled?(:focused_agent_runs, project:)
    end

    def flipper
      Rails.configuration.x.feature_flags.flipper
    end

    private

    def feature(flag_name)
      flipper[definition(flag_name).name]
    end

    def tenant_override(flag_name, project:)
      account = project&.account || Current.account
      return nil unless account

      features = account.tenant_setting&.features
      return nil unless features.is_a?(Hash)

      value = features[definition(flag_name).name.to_s]
      return value if [ true, false ].include?(value)

      nil
    end

    def resolve_actor(project:, actor:)
      raise InvalidActorError, "Pass either project: or actor:, not both" if project && actor

      return project if project
      return actor if actor

      nil
    end

    def update_percentage_gate(flipper_feature, gate, percentage)
      value = normalize_percentage(percentage)
      return flipper_feature.public_send("disable_percentage_of_#{gate}") if value.zero?

      flipper_feature.public_send("enable_percentage_of_#{gate}", value)
    end

    def normalize_percentage(percentage)
      return 0 if percentage.nil? || percentage == ""

      value = Integer(percentage, exception: false)
      raise InvalidPercentageError, "Percentage must be an integer between 0 and 100" unless value&.between?(0, 100)

      value
    end
  end
end
