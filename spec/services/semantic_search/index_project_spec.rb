# frozen_string_literal: true

require "rails_helper"

RSpec.describe SemanticSearch::IndexProject do
  let(:project) { create(:project) }
  let(:repo_path) { Dir.mktmpdir }

  after { FileUtils.rm_rf(repo_path) }

  describe ".call" do
    it "raises ArgumentError for non-existent repo path" do
      expect {
        described_class.call(project: project, repo_path: "/nonexistent/path")
      }.to raise_error(ArgumentError, /does not exist/)
    end

    context "with a Ruby file" do
      before do
        File.write(File.join(repo_path, "hello.rb"), <<~RUBY)
          class Greeter
            def hello
              puts "hello"
            end
          end
        RUBY
      end

      it "creates code chunks for the file" do
        stats = described_class.call(project: project, repo_path: repo_path)

        expect(stats[:files_scanned]).to eq(1)
        expect(stats[:chunks_created]).to be >= 1
        expect(project.code_chunks.count).to be >= 1
      end

      it "extracts function chunks" do
        described_class.call(project: project, repo_path: repo_path)

        function_chunk = project.code_chunks.find_by(chunk_type: "function", identifier: "hello")
        expect(function_chunk).to be_present
        expect(function_chunk.content).to include("def hello")
        expect(function_chunk.language).to eq("ruby")
      end

      it "extracts class chunks" do
        described_class.call(project: project, repo_path: repo_path)

        class_chunk = project.code_chunks.find_by(chunk_type: "class", identifier: "Greeter")
        expect(class_chunk).to be_present
        expect(class_chunk.content).to include("class Greeter")
      end
    end

    context "with a Python file" do
      before do
        File.write(File.join(repo_path, "app.py"), <<~PYTHON)
          class App:
              def run(self):
                  print("running")

          def main():
              app = App()
              app.run()
        PYTHON
      end

      it "extracts Python chunks" do
        described_class.call(project: project, repo_path: repo_path)

        function_chunk = project.code_chunks.find_by(chunk_type: "function", identifier: "main")
        expect(function_chunk).to be_present
        expect(function_chunk.language).to eq("python")
      end
    end

    context "with a JavaScript file" do
      before do
        File.write(File.join(repo_path, "app.js"), <<~JS)
          function greet(name) {
            console.log(`Hello, ${name}`);
          }

          class Greeter {
            constructor(name) {
              this.name = name;
            }
          }
        JS
      end

      it "extracts JavaScript chunks" do
        described_class.call(project: project, repo_path: repo_path)

        function_chunk = project.code_chunks.find_by(chunk_type: "function", identifier: "greet")
        expect(function_chunk).to be_present
        expect(function_chunk.language).to eq("javascript")
      end
    end

    context "with incremental re-indexing" do
      before do
        File.write(File.join(repo_path, "model.rb"), <<~RUBY)
          def unchanged
            "same"
          end
        RUBY
      end

      it "does not update unchanged chunks" do
        described_class.call(project: project, repo_path: repo_path)
        stats = described_class.call(project: project, repo_path: repo_path)

        expect(stats[:chunks_unchanged]).to be >= 1
        expect(stats[:chunks_updated]).to eq(0)
      end

      it "updates chunks when content changes" do
        described_class.call(project: project, repo_path: repo_path)

        File.write(File.join(repo_path, "model.rb"), <<~RUBY)
          def unchanged
            "different now"
          end
        RUBY

        stats = described_class.call(project: project, repo_path: repo_path)
        expect(stats[:chunks_updated]).to be >= 1
      end

      it "clears embedding when content changes" do
        described_class.call(project: project, repo_path: repo_path)
        chunk = project.code_chunks.first
        chunk.update!(embedding: Array.new(1536) { 0.1 })

        File.write(File.join(repo_path, "model.rb"), <<~RUBY)
          def unchanged
            "different"
          end
        RUBY

        described_class.call(project: project, repo_path: repo_path)
        expect(chunk.reload.embedding).to be_nil
      end
    end

    context "when filtering files" do
      it "skips non-indexable file types" do
        File.write(File.join(repo_path, "image.png"), "binary data")

        stats = described_class.call(project: project, repo_path: repo_path)
        expect(stats[:files_scanned]).to eq(0)
      end

      it "skips vendor directories" do
        FileUtils.mkdir_p(File.join(repo_path, "vendor/bundle"))
        File.write(File.join(repo_path, "vendor/bundle/gem.rb"), "class Gem; end")

        stats = described_class.call(project: project, repo_path: repo_path)
        expect(stats[:files_scanned]).to eq(0)
      end

      it "skips node_modules" do
        FileUtils.mkdir_p(File.join(repo_path, "node_modules/pkg"))
        File.write(File.join(repo_path, "node_modules/pkg/index.js"), "module.exports = {}")

        stats = described_class.call(project: project, repo_path: repo_path)
        expect(stats[:files_scanned]).to eq(0)
      end
    end

    context "when pruning removed files" do
      it "removes chunks for files that no longer exist" do
        File.write(File.join(repo_path, "old.rb"), "def old; end")
        described_class.call(project: project, repo_path: repo_path)

        expect(project.code_chunks.count).to be >= 1

        File.delete(File.join(repo_path, "old.rb"))
        described_class.call(project: project, repo_path: repo_path)

        expect(project.code_chunks.count).to eq(0)
      end
    end
  end
end
