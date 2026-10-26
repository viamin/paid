# frozen_string_literal: true

namespace :facet_confidence do
  namespace :corpus do
    desc "Run the frozen RDR-070 facet-confidence corpus for a project"
    task :run, [ :project_id ] => :environment do |_task, arguments|
      project_id = arguments.fetch(:project_id)
      raise ArgumentError, "project_id is required" if project_id.blank?

      FacetConfidence::RunCorpus.call(project_id:)
    end
  end
end
