# frozen_string_literal: true

module AgentRunResourceProfiles
  class Resolve
    def self.call(...)
      new(...).call
    end

    def initialize(project:, runner_key:, goal:)
      @project = project
      @runner_key = runner_key.presence
      @goal = goal.presence
    end

    def call
      fallback_chain.each do |entry|
        profile = find_profile(entry)
        next unless profile&.sufficient_samples?

        return {
          source: profile.profile_level,
          profile: profile,
          recommended_memory_limit_bytes: profile.recommended_memory_limit_bytes
        }
      end

      {
        source: "default",
        profile: nil,
        recommended_memory_limit_bytes: AgentRunResourceProfile::DEFAULT_ESTIMATE_MEMORY_LIMIT_BYTES
      }
    end

    private

    attr_reader :project, :runner_key, :goal

    def fallback_chain
      [
        specific_entry,
        runner_goal_entry,
        project_entry,
        account_entry,
        global_entry
      ].compact
    end

    def specific_entry
      return if project.blank? || runner_key.blank? || goal.blank?

      {
        profile_level: "specific",
        account_id: project.account_id,
        project_id: project.id,
        runner_key: runner_key,
        goal: goal
      }
    end

    def runner_goal_entry
      return if runner_key.blank? || goal.blank?

      {
        profile_level: "runner_goal",
        runner_key: runner_key,
        goal: goal
      }
    end

    def project_entry
      return if project.blank?

      {
        profile_level: "project",
        account_id: project.account_id,
        project_id: project.id
      }
    end

    def account_entry
      return if project.blank?

      {
        profile_level: "account",
        account_id: project.account_id
      }
    end

    def global_entry
      { profile_level: "global" }
    end

    def find_profile(entry)
      AgentRunResourceProfile.find_by(
        lookup_key: AgentRunResourceProfile.lookup_key_for(**entry)
      )
    end
  end
end
