# frozen_string_literal: true

FactoryBot.define do
  factory :agent_run_resource_profile do
    project
    account { project.account }
    profile_level { "specific" }
    runner_key { "claude" }
    goal { "create_pr" }
    sample_count { 3 }
    oom_count { 0 }
    p50_memory_bytes { 2 * 1024 * 1024 * 1024 }
    p95_memory_bytes { 3 * 1024 * 1024 * 1024 }
    max_memory_bytes { 3 * 1024 * 1024 * 1024 }
    recommended_memory_limit_bytes { 4 * 1024 * 1024 * 1024 }
    lookup_key do
      AgentRunResourceProfile.lookup_key_for(
        profile_level: profile_level,
        account_id: account_id,
        project_id: project_id,
        runner_key: runner_key,
        goal: goal
      )
    end

    trait :runner_goal do
      account { nil }
      project { nil }
      profile_level { "runner_goal" }
      lookup_key do
        AgentRunResourceProfile.lookup_key_for(
          profile_level: profile_level,
          runner_key: runner_key,
          goal: goal
        )
      end
    end

    trait :project_level do
      runner_key { nil }
      goal { nil }
      profile_level { "project" }
      lookup_key do
        AgentRunResourceProfile.lookup_key_for(
          profile_level: profile_level,
          account_id: account_id,
          project_id: project_id
        )
      end
    end

    trait :account_level do
      project { nil }
      runner_key { nil }
      goal { nil }
      profile_level { "account" }
      lookup_key do
        AgentRunResourceProfile.lookup_key_for(
          profile_level: profile_level,
          account_id: account_id
        )
      end
    end

    trait :global do
      account { nil }
      project { nil }
      runner_key { nil }
      goal { nil }
      profile_level { "global" }
      lookup_key do
        AgentRunResourceProfile.lookup_key_for(profile_level: profile_level)
      end
    end
  end
end
