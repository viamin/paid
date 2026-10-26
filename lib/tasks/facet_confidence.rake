# frozen_string_literal: true

namespace :facet_confidence do
  namespace :corpus do
    desc "Run the frozen facet-confidence corpus for a project"
    task :run, [ :project_id ] => :environment do |_task, arguments|
      project_id = Integer(arguments.fetch(:project_id))
      project = TenantContext.with_system_access { Project.includes(:account).find(project_id) }
      events = TenantContext.with(project.account) { FacetConfidence::CorpusRunner.call(project: project) }
      puts "Recorded #{events.count} facet-confidence corpus assessment runs."
    rescue ArgumentError, KeyError
      abort %(Usage: bin/rails 'facet_confidence:corpus:run[<project-id>]')
    end
  end
end
