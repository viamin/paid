# frozen_string_literal: true

require "rails_helper"

RSpec.describe SemanticSearch::IndexProject do
  let(:project) { create(:project) }
  let(:repo_path) { Dir.mktmpdir("test_repo") }

  after { FileUtils.rm_rf(repo_path) }

  def create_file(relative_path, content)
    full_path = File.join(repo_path, relative_path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, content)
  end

  describe ".call" do
    it "indexes Ruby files" do
      create_file("app/models/user.rb", "class User\n  def name\n    'test'\n  end\nend")

      stats = described_class.call(project: project, repo_path: repo_path)

      expect(stats[:indexed]).to eq(1)
      expect(project.code_chunks.count).to eq(1)

      chunk = project.code_chunks.first
      expect(chunk.file_path).to eq("app/models/user.rb")
      expect(chunk.chunk_type).to eq("file")
      expect(chunk.language).to eq("ruby")
    end

    it "indexes multiple file types" do
      create_file("app.rb", "puts 'hello'")
      create_file("src/app.js", "console.log('hello')")
      create_file("main.py", "print('hello')")

      stats = described_class.call(project: project, repo_path: repo_path)

      expect(stats[:indexed]).to eq(3)
      expect(project.code_chunks.pluck(:language)).to contain_exactly("ruby", "javascript", "python")
    end

    it "skips non-indexable file types" do
      create_file("image.png", "binary data")
      create_file("data.csv", "a,b,c")
      create_file("app.rb", "puts 'hello'")

      stats = described_class.call(project: project, repo_path: repo_path)

      expect(stats[:indexed]).to eq(1)
    end

    it "skips directories in SKIP_DIRECTORIES" do
      create_file("node_modules/pkg/index.js", "module.exports = {}")
      create_file("vendor/bundle/gems/foo.rb", "class Foo; end")
      create_file(".git/config", "gitconfig")
      create_file("app.rb", "puts 'hello'")

      stats = described_class.call(project: project, repo_path: repo_path)

      expect(stats[:indexed]).to eq(1)
      expect(project.code_chunks.first.file_path).to eq("app.rb")
    end

    it "performs incremental sync (skips unchanged files)" do
      create_file("app.rb", "puts 'hello'")

      described_class.call(project: project, repo_path: repo_path)
      stats = described_class.call(project: project, repo_path: repo_path)

      expect(stats[:skipped]).to eq(1)
      expect(stats[:indexed]).to eq(0)
      expect(project.code_chunks.count).to eq(1)
    end

    it "re-indexes changed files" do
      create_file("app.rb", "puts 'hello'")
      described_class.call(project: project, repo_path: repo_path)

      create_file("app.rb", "puts 'world'")
      stats = described_class.call(project: project, repo_path: repo_path)

      expect(stats[:indexed]).to eq(1)
      expect(project.code_chunks.first.content).to include("world")
    end

    it "removes chunks for deleted files" do
      create_file("app.rb", "puts 'hello'")
      create_file("lib.rb", "puts 'lib'")
      described_class.call(project: project, repo_path: repo_path)
      expect(project.code_chunks.count).to eq(2)

      FileUtils.rm(File.join(repo_path, "lib.rb"))
      stats = described_class.call(project: project, repo_path: repo_path)

      expect(stats[:removed]).to eq(1)
      expect(project.code_chunks.count).to eq(1)
      expect(project.code_chunks.first.file_path).to eq("app.rb")
    end

    it "splits large files into multiple chunks" do
      large_content = "x = 1\n" * 2000 # Well over MAX_CHUNK_SIZE
      create_file("large.rb", large_content)

      described_class.call(project: project, repo_path: repo_path)

      expect(project.code_chunks.count).to be > 1
      project.code_chunks.each do |chunk|
        expect(chunk.content.length).to be <= SemanticSearch::IndexProject::MAX_CHUNK_SIZE + 100 # allow margin for line boundaries
      end
    end

    it "does not cross-contaminate between projects" do
      other_project = create(:project)
      create_file("shared.rb", "puts 'shared'")

      described_class.call(project: project, repo_path: repo_path)

      expect(other_project.code_chunks.count).to eq(0)
      expect(project.code_chunks.count).to eq(1)
    end

    it "computes content hash for each chunk" do
      create_file("app.rb", "puts 'hello'")
      described_class.call(project: project, repo_path: repo_path)

      chunk = project.code_chunks.first
      expect(chunk.content_hash).to eq(Digest::SHA256.hexdigest("puts 'hello'"))
    end
  end
end
