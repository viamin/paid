# frozen_string_literal: true

FactoryBot.define do
  factory :apple_verification_attempt do
    project
    workflow_revision { association :apple_verification_workflow_revision, project: project }
    queue_position { 1 }
  end
end
