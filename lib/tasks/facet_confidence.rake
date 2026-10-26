# frozen_string_literal: true

namespace :facet_confidence do
  namespace :corpus do
    desc "Run the frozen RDR-070 assessment corpus through the shipped facet assessment path " \
      "and record the runs in the corpus ledger (usage: bin/rails " \
      "'facet_confidence:corpus:run[project_id]'). Records corpus, rubric/model, and input " \
      "provenance for every run, refuses to attribute a run served by another model, and " \
      "compiles the measured outcome measures."
    # @spec FACET-CONFIDENCE-022
    task :run, [ :project_id, :corpus_path, :ledger_path ] => :environment do |_task, args|
      project = TenantContext.with_system_access { Project.find(args.fetch(:project_id)) }
      TenantContext.apply!(project.account)

      result = FacetConfidence::AssessmentCorpusRunner.call(
        project: project,
        corpus_path: args[:corpus_path].presence || FacetConfidence::AssessmentCorpusRunner::DEFAULT_CORPUS_PATH,
        ledger_path: args[:ledger_path].presence || FacetConfidence::AssessmentCorpusRunner::DEFAULT_LEDGER_PATH
      )

      # An operational failure is recorded, not hidden: the operator sees why
      # a run produced no verdict.
      failure_note = lambda do |entry|
        outcome = entry.fetch(:outcome)
        outcome.failed? ? " (operational failure: #{outcome.failure_reason})" : ""
      end

      result.recorded.each { |entry| puts "recorded #{entry.fetch(:case_id)}#{failure_note.call(entry)}" }
      result.refused.each { |entry| puts "refused #{entry.fetch(:case_id)}: #{entry.fetch(:error)}" }
      puts result.report
      exit 1 unless result.success?
    ensure
      TenantContext.clear!
    end
  end
end
