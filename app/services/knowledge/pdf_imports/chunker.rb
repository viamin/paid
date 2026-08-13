# frozen_string_literal: true

module Knowledge
  module PdfImports
    class Chunker
      MAX_CHUNK_CHARS = 1200
      SUMMARY_SENTENCE_LIMIT = 2

      def initialize(document:)
        @document = document
      end

      def self.call(...)
        new(...).call
      end

      def call
        sequence = 0
        chunks = []

        document.pages.each do |page|
          heading = nil

          paragraphs_for(page.fetch(:text)).each do |paragraph|
            if heading_candidate?(paragraph)
              heading = paragraph
              next
            end

            split_content(paragraph).each do |content_part|
              full_content = [ heading, content_part ].compact.join("\n\n")
              chunks << build_chunk(
                chunk_type: "context",
                content: "Page #{page.fetch(:number)}\n#{full_content}",
                sequence: sequence,
                page_number: page.fetch(:number)
              )
              sequence += 1

              summary_content = summarize(content_part, heading:, page_number: page.fetch(:number))
              next if summary_content.blank?

              chunks << build_chunk(
                chunk_type: "summary",
                content: summary_content,
                sequence: sequence,
                page_number: page.fetch(:number)
              )
              sequence += 1
            end
          end
        end

        chunks
      end

      private

      attr_reader :document

      def paragraphs_for(text)
        text.split(/\n{2,}/).map(&:strip).reject(&:blank?)
      end

      def heading_candidate?(paragraph)
        return false if paragraph.length > 100
        return false if paragraph.include?(".")

        paragraph.lines.count <= 2 || paragraph == paragraph.upcase
      end

      def split_content(content)
        return [ content ] if content.length <= MAX_CHUNK_CHARS

        content.split(/(?<=[.!?])\s+/).each_with_object([ +"" ]) do |sentence, parts|
          current = parts.last

          if current.blank?
            current << sentence
          elsif current.length + sentence.length + 1 <= MAX_CHUNK_CHARS
            current << " #{sentence}"
          else
            parts << sentence.dup
          end
        end
      end

      def summarize(content, heading:, page_number:)
        sentences = content.split(/(?<=[.!?])\s+/).reject(&:blank?).first(SUMMARY_SENTENCE_LIMIT)
        summary = sentences.join(" ").presence || content.tr("\n", " ").truncate(220)
        label = [ heading, "page #{page_number}" ].compact.join(" - ")

        [ label.presence, summary ].compact.join(": ").truncate(280)
      end

      def build_chunk(chunk_type:, content:, sequence:, page_number:)
        {
          chunk_type: chunk_type,
          content: content,
          sequence: sequence,
          scope_tags: [ "pdf_import", "page_#{page_number}" ]
        }
      end
    end
  end
end
