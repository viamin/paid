# frozen_string_literal: true

module PromptAssembly
  # Resolves a prompt assembly profile from a hierarchy of configuration
  # overrides: global defaults → account → project → goal-specific.
  #
  # Each override level is a plain hash with optional keys
  # +disabled_sections+, +section_order+, and +budgets+. Later levels
  # (project over account, goal over project) take precedence.
  #
  # Safety enforcement is applied after resolution: any section that is
  # marked required by the assembler can never be disabled, regardless of
  # what the override config requests. The Profile itself enforces this
  # at assembly time via +section_enabled?+.
  #
  # @spec PROMPT-ASSEMBLY-012
  class ProfileResolution
    def self.resolve(project: nil, account: nil, goal: nil, overrides: {})
      new(
        project: project,
        account: account,
        goal: goal,
        overrides: overrides
      ).resolve
    end

    def initialize(project: nil, account: nil, goal: nil, overrides: {})
      @project = project
      @account = account || project&.account
      @goal = goal
      @overrides = overrides || {}
    end

    def resolve
      profile = Profile.default
      profile = merge_overrides(profile, global_config)
      profile = merge_overrides(profile, account_config)
      profile = merge_overrides(profile, project_config)
      profile = merge_overrides(profile, goal_config)
      profile = merge_overrides(profile, @overrides)
      profile
    end

    private

    attr_reader :project, :account, :goal

    def merge_overrides(profile, config)
      return profile if config.blank?

      profile.merge(Profile.new(**config))
    end

    def global_config
      {}
    end

    def account_config
      return {} unless account

      extract_profile_config(account_level_source)
    end

    def project_config
      return {} unless project

      extract_profile_config(project_level_source)
    end

    def goal_config
      return {} if goal.blank?

      goal_overrides = goal_level_source
      return {} if goal_overrides.blank?

      config = goal_overrides[goal.to_s] || goal_overrides[goal.to_sym] || {}
      extract_profile_config(config)
    end

    def account_level_source
      features = account&.tenant_setting&.features
      return {} unless features.is_a?(Hash)

      features["prompt_assembly_profile"] || {}
    end

    def project_level_source
      settings = project&.review_settings
      return {} unless settings.is_a?(Hash)

      settings["prompt_assembly_profile"] || {}
    end

    def goal_level_source
      project_level_source["goals"] || {}
    end

    def extract_profile_config(config)
      return {} unless config.is_a?(Hash)

      config.slice("disabled_sections", "section_order", "budgets")
        .transform_keys(&:to_sym)
    end
  end
end
