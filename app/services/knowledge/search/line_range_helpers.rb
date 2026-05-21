# frozen_string_literal: true

module Knowledge
  class Search
    module LineRangeHelpers
      private

      def start_line_for(artifact)
        artifact.metadata["start_line"] || artifact.metadata["line"]
      end

      def end_line_for(artifact)
        artifact.metadata["end_line"]
      end
    end
  end
end
