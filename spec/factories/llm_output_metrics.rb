# frozen_string_literal: true

FactoryBot.define do
  factory :llm_output_metric do
    project
    account { project.account }
    output_type { "pr_description" }
    prompt_slug { "generation.pr_description" }
    source_type { "PullRequest" }
    sequence(:source_id) { |n| n }
    scores { {} }
    metadata { {} }

    trait :pr_description do
      output_type { "pr_description" }
      prompt_slug { "generation.pr_description" }
      source_type { "PullRequest" }
    end

    trait :issue_title do
      output_type { "issue_title" }
      prompt_slug { "generation.issue_title" }
      source_type { "Issue" }
    end

    trait :decision_record do
      output_type { "decision_record" }
      prompt_slug { "knowledge.draft_decision" }
      source_type { "DecisionRecord" }
    end

    trait :with_prompt_version do
      prompt_version
    end

    trait :with_scores do
      scores do
        {
          "description_edited" => 1.0,
          "description_length_ratio" => 0.8,
          "pr_reaction" => 1.0
        }
      end
      composite_score { 0.94 }
    end
  end
end
