# frozen_string_literal: true

require Rails.root.join("lib/facet_confidence/corpus_runner")

namespace :facet_confidence do
  namespace :corpus do
    desc "Run the frozen RDR-070 corpus with its pinned rubric model (usage: bin/rails 'facet_confidence:corpus:run[<project-id>]')"
    # @spec FACET-CONFIDENCE-017 FACET-CONFIDENCE-018
    task :run, [ :project_id ] => :environment do |_task, args|
      project, account = TenantContext.with_system_access do
        project = Project.find(args.fetch(:project_id))
        [ project, project.account ]
      end
      TenantContext.apply!(account)

      result = FacetConfidence::CorpusRunner.call(
        corpus_path: Rails.root.join("docs/intent/facet-confidence/assessment-corpus-manifest-v1.yml"),
        ledger_path: Rails.root.join("docs/intent/facet-confidence/assessment-evaluation-2026-10-23/ledger.jsonl")
      )
      puts "attempted=#{result.attempted} completed=#{result.completed} failed=#{result.failed} project_id=#{project.id}"
    ensure
      TenantContext.clear!
    end
  end
end
