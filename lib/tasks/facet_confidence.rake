# frozen_string_literal: true

namespace :facet_confidence do
  namespace :corpus do
    desc "Run the frozen facet-confidence corpus with its pinned rubric model"
    task :run, [ :project_id ] => :environment do |_task, arguments|
      abort "project_id is required" if arguments[:project_id].blank?

      FacetConfidence::CorpusRunner.call(project: Project.find(arguments[:project_id]))
    end
  end
end
