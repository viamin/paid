# frozen_string_literal: true

FactoryBot.define do
  factory :project_delegation_intent_checkpoint, class: "ProjectDelegation::IntentCheckpoint" do
    feature_intent
    status { "open" }
    recommendation { "Prefer the narrow rollout." }
    alternatives { [ { "label" => "Broad rollout", "tradeoff" => "Higher migration risk" } ] }
    consequences { [ "Existing customers remain unchanged." ] }
    affected_scope { { "paths" => [ "app/models" ] } }
    evidence { [ { "source" => "design", "reference" => "RDR-080" } ] }
    proposed_design_revision { "design-1" }
    proposed_acceptance_revision { "acceptance-1" }
  end

  factory :project_delegation_intent_settlement, class: "ProjectDelegation::IntentSettlement" do
    intent_checkpoint factory: :project_delegation_intent_checkpoint
    settled_by { create(:user, account: intent_checkpoint.feature_intent.project.account) }
    disposition { "settled" }
    answers { {} }
    design_revision { "design-1" }
    acceptance_revision { "acceptance-1" }
    settled_at { 1.hour.ago }
  end
end
