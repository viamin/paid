# frozen_string_literal: true

require "pdf/reader"

module Knowledge
  module PdfImports
    class Parser
      ParsedDocument = Struct.new(:title, :page_count, :pages, :source_name, keyword_init: true)

      def initialize(file:)
        @file = file
      end

      def self.call(...)
        new(...).call
      end

      def call
        io = source_io
        reader = PDF::Reader.new(io)
        pages = reader.pages.map.with_index(1) do |page, page_number|
          text = normalize_text(page.text)
          next if text.blank?

          { number: page_number, text: text }
        end.compact

        raise ImportError, "The PDF did not contain extractable text." if pages.empty?

        ParsedDocument.new(
          title: normalized_title(reader),
          page_count: reader.page_count,
          pages: pages,
          source_name: source_name
        )
      rescue PDF::Reader::MalformedPDFError, PDF::Reader::EncryptedPDFError,
        PDF::Reader::UnsupportedFeatureError, ArgumentError => e
        raise ImportError, "Could not read PDF: #{e.message}"
      ensure
        io&.rewind if io.respond_to?(:rewind)
      end

      private

      attr_reader :file

      def source_io
        io = file.respond_to?(:tempfile) ? file.tempfile : file
        io.rewind if io.respond_to?(:rewind)
        io
      end

      def source_name
        file.respond_to?(:original_filename) ? file.original_filename.to_s : "document.pdf"
      end

      def normalized_title(reader)
        raw_title = reader.info&.[](:Title) || reader.info&.[]("Title")
        raw_title.to_s.strip.presence || File.basename(source_name, ".*").tr("_-", " ").squish.titleize
      end

      def normalize_text(text)
        text.to_s
          .encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
          .gsub(/\u0000/, "")
          .gsub(/\r\n?/, "\n")
          .gsub(/[ \t]+/, " ")
          .gsub(/\n{3,}/, "\n\n")
          .strip
      end
    end
  end
end
