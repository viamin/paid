# frozen_string_literal: true

FactoryBot.define do
  factory :project_service_container do
    project
    service_container { association :service_container, account: project.account }

    before(:create) do |project_service_container|
      service_container = project_service_container.service_container
      project = project_service_container.project
      service_container.update!(account: project.account) if service_container.account_id != project.account_id
    end
  end
end
