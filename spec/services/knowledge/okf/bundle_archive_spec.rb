# frozen_string_literal: true

require "rails_helper"
require "rubygems/package"
require "zlib"
require "stringio"

# @spec KNOWLEDGE-OKF-005
RSpec.describe Knowledge::Okf::BundleArchive do
  describe ".build" do
    it "packages files into a gzip-compressed tar readable back with the same paths and content" do
      files = [
        Knowledge::Okf::Export::BundleFile.new(relative_path: "okf_concept/auth-flows-1.md", content: "---\ntitle: Auth\n---\n\nBody one.\n"),
        Knowledge::Okf::Export::BundleFile.new(relative_path: "route/get-users-2.md", content: "---\ntitle: Users\n---\n\nBody two.\n")
      ]

      archive = described_class.build(files)
      extracted = {}
      Gem::Package::TarReader.new(Zlib::GzipReader.new(StringIO.new(archive))) do |tar|
        tar.each { |entry| extracted[entry.full_name] = entry.read }
      end

      expect(extracted.keys).to contain_exactly("okf_concept/auth-flows-1.md", "route/get-users-2.md")
      expect(extracted["okf_concept/auth-flows-1.md"]).to eq(files.first.content)
      expect(extracted["route/get-users-2.md"]).to eq(files.last.content)
    end

    it "returns a valid empty archive when there are no files" do
      archive = described_class.build([])

      entries = []
      Gem::Package::TarReader.new(Zlib::GzipReader.new(StringIO.new(archive))) do |tar|
        tar.each { |entry| entries << entry.full_name }
      end

      expect(entries).to be_empty
    end
  end
end
