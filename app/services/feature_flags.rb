# frozen_string_literal: true

class FeatureFlags
  Definition = Data.define(:name, :owner, :intent, :rollout_plan, :cleanup_criteria)

  UnknownFlagError = Class.new(ArgumentError)
  InvalidActorError = Class.new(ArgumentError)
  InvalidPercentageError = Class.new(ArgumentError)

  DEFINITIONS = {
    context_intake_agent_questions: Definition.new(
      name: :context_intake_agent_questions,
      owner: "context-intake",
      intent: "Enable LLM-generated follow-up questions during the business context wizard",
      rollout_plan: "Per-tenant opt-in via tenant_settings.features, then percentage-of-actors rollout",
      cleanup_criteria: "Remove when AI-generated questions are the default for all tenants"
    ),
    managed_subscription_runner_auth: Definition.new(
      name: :managed_subscription_runner_auth,
      owner: "runner-auth",
      intent: "Gate the rollout of managed RunnerCredential auth for subscription runners (Claude, Codex, Gemini, Copilot) ahead of remote cutover (RDR-041 / #2959 / #2960).",
      rollout_plan: "Shadow read-only by default; opt-in per tenant via tenant_settings.features; default-on after telemetry proves reliability versus legacy host-mounted auth.",
      cleanup_criteria: "Remove once managed auth is the default for all subscription runners and legacy host-mounted paths are documented as local-only escape hatches."
    ),
    execution_runner_enabled: Definition.new(
      name: :execution_runner_enabled,
      owner: "container-runtime",
      intent: "Route AgentRun container operations through ExecutionRunners::LocalDockerRunner instead of direct Containers::Provision calls (RDR-054).",
      rollout_plan: "Opt-in per tenant via tenant_settings.features; default-off until Phase A–C migration is complete.",
      cleanup_criteria: "Remove once all orchestration callers use the runner interface and direct Containers::Provision calls are retired."
    ),
    prompt_assembly: Definition.new(
      name: :prompt_assembly,
      owner: "prompt-assembly",
      intent: "Route PR prompt construction and runner-time goal wrappers through PromptAssembly instead of legacy prompt builders.",
      rollout_plan: "Default-off; opt in per tenant or project, then percentage-of-actors only after completion, loop, token, failure, and merge metrics improve or match legacy.",
      cleanup_criteria: "Remove only after measured A/B validation makes PromptAssembly the default for all tenants."
    ),
    prompt_assembly_shadow_compare: Definition.new(
      name: :prompt_assembly_shadow_compare,
      owner: "prompt-assembly",
      intent: "Build both legacy and PromptAssembly PR prompts for the same run input and persist a capped data-only comparison without changing the served prompt.",
      rollout_plan: "Default-off; enable only for scoped prompt investigation because it builds the alternate prompt path.",
      cleanup_criteria: "Remove once PromptAssembly parity is proven or a dedicated prompt comparison UI exists."
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
