# frozen_string_literal: true

Rails.application.config.to_prepare do
  Automation::Providers::Resolver.reset!(:github)
  Automation::Providers::Resolver.register(
    :github,
    repository: ->(project, client: nil) { Automation::Providers::Github::RepositoryProvider.new(project, client: client) },
    work_item: ->(project, client: nil) { Automation::Providers::Github::WorkItemProvider.new(project, client: client) },
    review: ->(project, client: nil) { Automation::Providers::Github::ReviewProvider.new(project, client: client) }
  )
end
