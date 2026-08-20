# frozen_string_literal: true

# Zeitwerk autoloads StyleGuides::ExtractionError from its own file. The
# constant previously lived at the top of extract.rb, which broke autoloading
# for callers (e.g. app/jobs/style_guide_extraction_job.rb) that reference the
# error class without loading StyleGuides::Extract first.
module StyleGuides
  class ExtractionError < StandardError; end
end
