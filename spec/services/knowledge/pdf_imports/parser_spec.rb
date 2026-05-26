# frozen_string_literal: true

require "rails_helper"

RSpec.describe Knowledge::PdfImports::Parser do
  let(:file) do
    instance_double(
      ActionDispatch::Http::UploadedFile,
      original_filename: "modern_css.pdf",
      tempfile: StringIO.new("pdf")
    )
  end

  it "extracts normalized page text and title metadata" do
    page = instance_double(PDF::Reader::Page, text: "  CSS\n\nLayouts\t\tand spacing  ")
    reader = instance_double(PDF::Reader, pages: [ page ], page_count: 1, info: { Title: "Modern CSS" })

    allow(PDF::Reader).to receive(:new).and_return(reader)

    document = described_class.call(file: file)

    expect(document.title).to eq("Modern CSS")
    expect(document.page_count).to eq(1)
    expect(document.pages).to eq([ { number: 1, text: "CSS\n\nLayouts and spacing" } ])
    expect(document.source_name).to eq("modern_css.pdf")
  end

  it "raises when the PDF has no extractable text" do
    page = instance_double(PDF::Reader::Page, text: "   ")
    reader = instance_double(PDF::Reader, pages: [ page ], page_count: 1, info: {})

    allow(PDF::Reader).to receive(:new).and_return(reader)

    expect {
      described_class.call(file: file)
    }.to raise_error(Knowledge::PdfImports::ImportError, "The PDF did not contain extractable text.")
  end
end
