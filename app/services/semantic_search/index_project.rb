# frozen_string_literal: true

module SemanticSearch
  # Indexes a project's source code into CodeChunk records for semantic search.
  #
  # Walks the repository file tree, chunks files by function/class definitions,
  # and stores them with content hashes for incremental re-indexing.
  # Embedding generation is handled separately via an embedding API.
  #
  # @example
  #   SemanticSearch::IndexProject.call(project: project, repo_path: "/path/to/repo")
  class IndexProject
    INDEXABLE_EXTENSIONS = %w[
      .rb .py .js .ts .jsx .tsx .go .rs .java .kt .swift .c .cpp .h .hpp
      .cs .ex .exs .clj .scala .sh .bash .zsh .yml .yaml .json .toml .md
    ].freeze

    MAX_FILE_SIZE = 100_000 # 100KB
    MAX_CHUNK_SIZE = 10_000 # 10KB

    attr_reader :project, :repo_path, :stats

    def initialize(project:, repo_path:)
      @project = project
      @repo_path = repo_path
      @stats = { files_scanned: 0, chunks_created: 0, chunks_updated: 0, chunks_unchanged: 0 }
    end

    def self.call(...)
      new(...).call
    end

    def call
      validate!
      indexed_paths = Set.new

      walk_files do |file_path|
        @stats[:files_scanned] += 1
        chunks = chunk_file(file_path)
        chunks.each do |chunk_attrs|
          upsert_chunk(chunk_attrs)
          indexed_paths.add([ chunk_attrs[:file_path], chunk_attrs[:chunk_type], chunk_attrs[:identifier] ])
        end
      end

      prune_removed_files(indexed_paths)

      log_completion
      @stats
    end

    private

    def validate!
      raise ArgumentError, "repo_path does not exist: #{repo_path}" unless File.directory?(repo_path)
    end

    def walk_files(&block)
      Dir.glob(File.join(repo_path, "**", "*")).each do |path|
        next unless File.file?(path)
        next unless indexable?(path)
        next if ignored?(path)

        relative_path = path.sub("#{repo_path}/", "")
        yield relative_path
      end
    end

    def indexable?(path)
      ext = File.extname(path).downcase
      INDEXABLE_EXTENSIONS.include?(ext) && File.size(path) <= MAX_FILE_SIZE
    end

    def ignored?(path)
      relative = path.sub("#{repo_path}/", "")
      relative.start_with?("vendor/", "node_modules/", ".git/", "tmp/", "log/", "coverage/")
    end

    def chunk_file(relative_path)
      full_path = File.join(repo_path, relative_path)
      content = File.read(full_path, encoding: "UTF-8")
      language = detect_language(relative_path)

      chunks = extract_chunks(content, language, relative_path)

      # Always include file-level chunk as fallback
      if chunks.empty? || content.length <= MAX_CHUNK_SIZE
        chunks = [ {
          file_path: relative_path,
          chunk_type: "file",
          identifier: File.basename(relative_path),
          content: content.truncate(MAX_CHUNK_SIZE),
          language: language,
          start_line: 1,
          end_line: content.count("\n") + 1
        } ]
      end

      chunks
    rescue EncodingError, Errno::ENOENT
      []
    end

    def extract_chunks(content, language, file_path)
      case language
      when "ruby"
        extract_ruby_chunks(content, file_path)
      when "python"
        extract_python_chunks(content, file_path)
      when "javascript", "typescript"
        extract_js_chunks(content, file_path)
      else
        []
      end
    end

    def extract_ruby_chunks(content, file_path)
      chunks = []
      lines = content.lines

      lines.each_with_index do |line, index|
        if line.match?(/^\s*(def|class|module)\s+\w/)
          match = line.match(/^\s*(def|class|module)\s+(\S+)/)
          next unless match

          chunk_type = match[1] == "def" ? "function" : match[1]
          identifier = match[2]
          start_line = index + 1
          end_line = find_ruby_end(lines, index)
          chunk_content = lines[index..end_line].join

          next if chunk_content.length > MAX_CHUNK_SIZE

          chunks << {
            file_path: file_path,
            chunk_type: chunk_type,
            identifier: identifier,
            content: chunk_content,
            language: "ruby",
            start_line: start_line,
            end_line: end_line + 1
          }
        end
      end

      chunks
    end

    def extract_python_chunks(content, file_path)
      chunks = []
      lines = content.lines

      lines.each_with_index do |line, index|
        if line.match?(/^(def|class)\s+\w/)
          match = line.match(/^(def|class)\s+(\w+)/)
          next unless match

          chunk_type = match[1] == "def" ? "function" : match[1]
          identifier = match[2]
          start_line = index + 1
          end_line = find_python_end(lines, index)
          chunk_content = lines[index..end_line].join

          next if chunk_content.length > MAX_CHUNK_SIZE

          chunks << {
            file_path: file_path,
            chunk_type: chunk_type,
            identifier: identifier,
            content: chunk_content,
            language: "python",
            start_line: start_line,
            end_line: end_line + 1
          }
        end
      end

      chunks
    end

    def extract_js_chunks(content, file_path)
      chunks = []
      lines = content.lines
      language = File.extname(file_path).delete(".").sub("jsx", "javascript").sub("tsx", "typescript")

      lines.each_with_index do |line, index|
        if line.match?(/^\s*(export\s+)?(async\s+)?function\s+\w|^\s*class\s+\w/)
          match = line.match(/(function|class)\s+(\w+)/)
          next unless match

          chunk_type = match[1] == "function" ? "function" : match[1]
          identifier = match[2]
          start_line = index + 1
          end_line = find_brace_end(lines, index)
          chunk_content = lines[index..end_line].join

          next if chunk_content.length > MAX_CHUNK_SIZE

          chunks << {
            file_path: file_path,
            chunk_type: chunk_type,
            identifier: identifier,
            content: chunk_content,
            language: language,
            start_line: start_line,
            end_line: end_line + 1
          }
        end
      end

      chunks
    end

    def find_ruby_end(lines, start_index)
      indent = lines[start_index][/^\s*/].length
      (start_index + 1...lines.length).each do |i|
        line = lines[i]
        next if line.strip.empty?

        if line.match?(/^\s{0,#{indent}}end\b/)
          return i
        end
      end
      [ start_index + 20, lines.length - 1 ].min
    end

    def find_python_end(lines, start_index)
      indent = lines[start_index][/^\s*/].length
      (start_index + 1...lines.length).each do |i|
        line = lines[i]
        next if line.strip.empty?

        current_indent = line[/^\s*/].length
        return i - 1 if current_indent <= indent
      end
      lines.length - 1
    end

    def find_brace_end(lines, start_index)
      depth = 0
      (start_index...lines.length).each do |i|
        depth += lines[i].count("{") - lines[i].count("}")
        return i if depth <= 0 && i > start_index
      end
      [ start_index + 30, lines.length - 1 ].min
    end

    def detect_language(file_path)
      case File.extname(file_path).downcase
      when ".rb" then "ruby"
      when ".py" then "python"
      when ".js", ".jsx" then "javascript"
      when ".ts", ".tsx" then "typescript"
      when ".go" then "go"
      when ".rs" then "rust"
      when ".java" then "java"
      when ".md" then "markdown"
      else "unknown"
      end
    end

    def upsert_chunk(attrs)
      content_hash = Digest::SHA256.hexdigest(attrs[:content])

      existing = project.code_chunks.find_by(
        file_path: attrs[:file_path],
        chunk_type: attrs[:chunk_type],
        identifier: attrs[:identifier]
      )

      if existing
        if existing.content_hash == content_hash
          @stats[:chunks_unchanged] += 1
        else
          existing.update!(
            content: attrs[:content],
            content_hash: content_hash,
            start_line: attrs[:start_line],
            end_line: attrs[:end_line],
            language: attrs[:language],
            embedding: nil # Clear embedding so it gets re-generated
          )
          @stats[:chunks_updated] += 1
        end
      else
        project.code_chunks.create!(
          file_path: attrs[:file_path],
          chunk_type: attrs[:chunk_type],
          identifier: attrs[:identifier],
          content: attrs[:content],
          content_hash: content_hash,
          start_line: attrs[:start_line],
          end_line: attrs[:end_line],
          language: attrs[:language]
        )
        @stats[:chunks_created] += 1
      end
    end

    def prune_removed_files(indexed_paths)
      project.code_chunks.find_each do |chunk|
        key = [ chunk.file_path, chunk.chunk_type, chunk.identifier ]
        chunk.destroy! unless indexed_paths.include?(key)
      end
    end

    def log_completion
      Rails.logger.info(
        message: "semantic_search.index_complete",
        project_id: project.id,
        **@stats
      )
    end
  end
end
