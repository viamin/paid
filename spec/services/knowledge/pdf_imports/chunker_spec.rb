# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::PdfImports::Chunker do
  let(:document) do
    Knowledge::PdfImports::Parser::ParsedDocument.new(
      title: "Modern CSS",
      page_count: 1,
      source_name: "modern_css.pdf",
      pages: [
        {
          number: 1,
          text: "LAYOUT PRINCIPLES\n\nUse grid for two-dimensional layouts. Prefer gaps over margin shims."
        }
      ]
    )
  end

  it "creates context and summary chunks while preserving page and heading context" do
    chunks = described_class.call(document: document)

    expect(chunks.map { |chunk| chunk[:chunk_type] }).to eq(%w[context summary])
    expect(chunks.first[:content]).to include("Page 1")
    expect(chunks.first[:content]).to include("LAYOUT PRINCIPLES")
    expect(chunks.last[:content]).to include("LAYOUT PRINCIPLES - page 1")
    expect(chunks.first[:scope_tags]).to include("pdf_import", "page_1")
  end
end
