# frozen_string_literal: true

# @spec PROJECT-DELEGATION-007
FactoryBot.define do
    factory :project_delegation_expansion_pause, class: "ProjectDelegation::ExpansionPause" do
    account { project.account }
    project
    reason { "material_reversal" }
    posture_before { "bounded_delivery" }
    detail { "A settled decision was reversed by delegated work." }
    evidence { {} }
  end
end
