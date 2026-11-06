# frozen_string_literal: true

# @spec PROJECT-DELEGATION-002
FactoryBot.define do
    factory :project_delegation_settlement, class: "ProjectDelegation::Settlement" do
    checkpoint { association :project_delegation_checkpoint }
    account { checkpoint.account }
    project { checkpoint.project }
    settled_by { association :user, account: }
    decision { "settled" }
    answers { checkpoint.groups.map { |group| { "key" => group["key"], "choice" => "recommended" } } }
    design_revision { checkpoint.design_revision }
    acceptance_revision { checkpoint.acceptance_revision }
  end
end
