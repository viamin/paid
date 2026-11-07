# frozen_string_literal: true

# @spec PROJECT-DELEGATION-001
FactoryBot.define do
  factory :project_delegation_posture do
    account { project.account }
    project
    selected_by { association :user, account: }
    level { "bounded_delivery" }
    revision { 1 }
    enabled_action_classes { ProjectDelegation::Posture::DELEGATED_ACTION_CLASSES }
    policy_signature { Digest::SHA256.hexdigest("posture") }
  end
end
