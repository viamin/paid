# frozen_string_literal: true

# @spec PROJECT-DELEGATION-002
FactoryBot.define do
    factory :project_delegation_checkpoint, class: "ProjectDelegation::Checkpoint" do
    account { project.account }
    project
    issue { association :issue, project: }
    design_revision { SecureRandom.hex(20) }
    acceptance_revision { SecureRandom.hex(8) }
    status { "open" }
    groups do
      [
        {
          "key" => "retention",
          "topic" => "Export retention",
          "question" => "How long should completed exports be retained?",
          "recommendation" => "Retain exports for 30 days with a storage cap.",
          "alternatives" => [ { "label" => "7 days", "tradeoff" => "Lower storage cost." } ],
          "consequences" => "Longer retention increases storage cost and can surface stale exports.",
          "affected_scope" => [ "exports" ],
          "evidence" => [ "issue #4871" ]
        }
      ]
    end
  end
end
