# frozen_string_literal: true

namespace :facet_confidence do
  namespace :corpus do
    desc "Run the frozen RDR-070 facet-confidence corpus for a project"
    task :run, [ :project_id ] => :environment do |_task, arguments|
      project_id = arguments.fetch(:project_id)
      raise ArgumentError, "project_id is required" if project_id.blank?

      results = FacetConfidence::CorpusRunner.call(project: Project.find(project_id))
      results.each { |result| puts "#{result.case_id}: #{result.assessment_status}" }
    end
  end
end
