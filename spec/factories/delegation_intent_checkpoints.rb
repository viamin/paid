# frozen_string_literal: true

# @spec PROJECT-DELEGATION-002
FactoryBot.define do
  factory :delegation_intent_checkpoint do
    account { project.account }
    project
    issue { association :issue, project: project }
    feature_intent { nil }
    status { "pending" }
    design_revision { "intent:#{SecureRandom.hex(16)}" }
    acceptance_revision { "criteria:#{SecureRandom.hex(16)}" }
    evidence_revision { nil }
    question_groups { [ { "key" => "claim:test", "question" => "Should X apply to new records?", "recommendation" => "New records only.",
                          "alternatives" => [], "consequences" => "Binding settles the design claim.", "affected_scope" => "The feature must support X.",
                          "evidence" => [], "source" => "needs_input_questions" } ] }
    question_set_digest { Digest::SHA256.hexdigest(question_groups.map { |group| group["question"] }.join) }
    created_by { nil }
  end

  factory :delegation_intent_settlement do
    delegation_intent_checkpoint
    disposition { "settled" }
    answers { [ { "group_key" => "claim:test", "answer" => "New records only." } ] }
    design_revision { delegation_intent_checkpoint.design_revision }
    acceptance_revision { delegation_intent_checkpoint.acceptance_revision }
    settled_by { association :user, account: delegation_intent_checkpoint.account }
    settled_at { Time.current }
  end
end
