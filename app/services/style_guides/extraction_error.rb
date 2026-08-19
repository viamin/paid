# frozen_string_literal: true

# Split out of extraction_error.rb's former home inside extract.rb so Zeitwerk
# can resolve +StyleGuides::ExtractionError+ from its own file. Before this
# split, the constant was defined at the top of extract.rb; that worked only
# incidentally (when extract.rb happened to load first) and broke autoloading
# for callers like app/jobs/style_guide_extraction_job.rb that reference the
# error class without loading +Extract+ directly. This fix is unrelated to
# RDR-062 / #3403 (network policy intent) — it is called out explicitly here,
# per code review, because splitting it into its own PR at this point in the
# branch's history would require rewriting already-shared commits.
module StyleGuides
  class ExtractionError < StandardError; end
end
