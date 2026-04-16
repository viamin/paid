# frozen_string_literal: true

Rails.application.config.to_prepare do
  Automation::Providers::Resolver.reset!(:github)
  Automation::Providers::Resolver.register(
    :github,
    repository: ->(project) { Automation::Providers::Github::RepositoryProvider.new(project) },
    work_item: ->(project) { Automation::Providers::Github::WorkItemProvider.new(project) },
    review: ->(project) { Automation::Providers::Github::ReviewProvider.new(project) }
  )
end
