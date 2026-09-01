# frozen_string_literal: true

require "rubygems/package"
require "zlib"
require "stringio"

module Knowledge
  module Okf
    # Packages Knowledge::Okf::Export::BundleFile entries into a downloadable
    # tar.gz archive using only Ruby's stdlib (no new gem dependency).
    module BundleArchive
      module_function

      # @spec KNOWLEDGE-OKF-005
      def build(files)
        tar_io = StringIO.new
        Gem::Package::TarWriter.new(tar_io) do |tar|
          files.each { |file| add_file(tar, file) }
        end

        gzip(tar_io.string)
      end

      def add_file(tar, file)
        tar.add_file_simple(file.relative_path, 0o644, file.content.bytesize) do |io|
          io.write(file.content)
        end
      end

      def gzip(tar_bytes)
        gz_io = StringIO.new
        writer = Zlib::GzipWriter.new(gz_io)
        writer.write(tar_bytes)
        writer.close
        gz_io.string
      end
    end
  end
end
