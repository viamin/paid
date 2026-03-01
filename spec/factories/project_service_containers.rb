# frozen_string_literal: true

FactoryBot.define do
  factory :project_service_container do
    project
    service_container
  end
end
