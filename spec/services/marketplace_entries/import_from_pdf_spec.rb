# frozen_string_literal: true

require "rails_helper"

RSpec.describe MarketplaceEntries::ImportFromPdf do
  let(:account) { create(:account, plan: "professional") }
  let(:actor) { create(:user, :member, account: account) }
  let(:file) do
    instance_double(
      ActionDispatch::Http::UploadedFile,
      original_filename: "modern_css.pdf",
      content_type: "application/pdf",
      size: 1.megabyte
    )
  end
  let(:document) do
    Knowledge::PdfImports::Parser::ParsedDocument.new(
      title: "Modern CSS",
      page_count: 1,
      source_name: "modern_css.pdf",
      pages: [ { number: 1, text: "Prefer grid and gap." } ]
    )
  end
  let(:chunks) do
    [
      { chunk_type: "summary", content: "Layout guidance - page 1: Prefer grid and gap.", sequence: 0, scope_tags: [ "pdf_import", "page_1" ] }
    ]
  end

  before do
    allow(Knowledge::PdfImports::Parser).to receive(:call).and_return(document)
    allow(Knowledge::PdfImports::Chunker).to receive(:call).and_return(chunks)
  end

  it "creates a marketplace entry with prompt-ready imported content" do
    entry = described_class.call(
      account: account,
      actor: actor,
      params: {
        name: "Modern CSS Coach",
        entry_type: "skill",
        description: "",
        usage_guidance: "",
        tags_csv: "css,frontend",
        status: "active",
        pdf_file: file
      }
    )

    expect(entry).to be_persisted
    expect(entry.current_version).to be_present
    expect(entry.current_version.canonical_artifact.fetch("attachment_strategy")).to eq("prompt_append")
    expect(entry.current_version.canonical_artifact.fetch("content")).to include("Reference material: Modern CSS")
    expect(entry.current_version.canonical_artifact.fetch("content")).to include("Prefer grid and gap")
  end

  it "rejects oversized PDFs" do
    allow(file).to receive(:size).and_return(51.megabytes)

    expect {
      described_class.call(
        account: account,
        actor: actor,
        params: { pdf_file: file }
      )
    }.to raise_error(described_class::ImportError, "PDF must be smaller than 50 MB.")
  end
end
