# frozen_string_literal: true

# Review-time contract for staged closeout verification. It deliberately does
# not enqueue a run; #5074 consumes its eligible mappings.
module StagedCloseoutAdoption
  class Error < StandardError; end
end
