# frozen_string_literal: true

module SemanticSearch
  # Indexes a project's source code into code chunks with embeddings
  # for semantic search. Walks the git tree, chunks files by function/class,
  # and generates vector embeddings for each chunk.
  #
  # Uses content hashing for incremental sync — only re-indexes changed files.
  #
  # @example
  #   SemanticSearch::IndexProject.call(project: project, repo_path: "/path/to/repo")
  class IndexProject
    INDEXABLE_EXTENSIONS = %w[.rb .js .ts .jsx .tsx .py .go .rs .md].freeze
    MAX_CHUNK_SIZE = 8000 # characters, conservative for embedding model context
    SKIP_DIRECTORIES = %w[node_modules vendor .git tmp log coverage dist build .bundle].freeze

    attr_reader :project, :repo_path, :stats

    def initialize(project:, repo_path:)
      @project = project
      @repo_path = repo_path
      @stats = { indexed: 0, skipped: 0, removed: 0 }
    end

    def self.call(...)
      new(...).call
    end

    def call
      indexed_paths = []

      walk_files do |file_path, relative_path|
        chunks = chunk_file(file_path, relative_path)
        chunks.each { |chunk| upsert_chunk(chunk) }
        indexed_paths << relative_path
      end

      remove_stale_chunks(indexed_paths)

      log_completion
      stats
    end

    private

    def walk_files(&block)
      Dir.glob(File.join(repo_path, "**", "*")).each do |file_path|
        next unless File.file?(file_path)

        relative_path = file_path.sub("#{repo_path}/", "")
        next if skip_path?(relative_path)
        next unless indexable_extension?(file_path)

        yield file_path, relative_path
      end
    end

    def skip_path?(relative_path)
      SKIP_DIRECTORIES.any? { |dir| relative_path.start_with?("#{dir}/") }
    end

    def indexable_extension?(file_path)
      INDEXABLE_EXTENSIONS.include?(File.extname(file_path).downcase)
    end

    def chunk_file(file_path, relative_path)
      content = File.read(file_path, encoding: "UTF-8")
      language = detect_language(file_path)

      # For now, use file-level chunking. Phase 2 will add AST-aware
      # chunking via Arcaneum or tree-sitter.
      if content.length <= MAX_CHUNK_SIZE
        [build_chunk(relative_path, "file", nil, content, language)]
      else
        split_into_chunks(relative_path, content, language)
      end
    rescue Encoding::InvalidByteSequenceError, Encoding::UndefinedConversionError
      @stats[:skipped] += 1
      []
    end

    def split_into_chunks(relative_path, content, language)
      lines = content.lines
      chunks = []
      current_chunk = []
      current_size = 0
      chunk_start_line = 1

      lines.each_with_index do |line, index|
        if current_size + line.length > MAX_CHUNK_SIZE && current_chunk.any?
          chunk_content = current_chunk.join
          chunks << build_chunk(
            relative_path, "file", "part_#{chunks.length + 1}",
            chunk_content, language,
            start_line: chunk_start_line, end_line: chunk_start_line + current_chunk.length - 1
          )
          current_chunk = []
          current_size = 0
          chunk_start_line = index + 1
        end

        current_chunk << line
        current_size += line.length
      end

      if current_chunk.any?
        chunk_content = current_chunk.join
        chunks << build_chunk(
          relative_path, "file", "part_#{chunks.length + 1}",
          chunk_content, language,
          start_line: chunk_start_line, end_line: chunk_start_line + current_chunk.length - 1
        )
      end

      chunks
    end

    def build_chunk(file_path, chunk_type, identifier, content, language, start_line: nil, end_line: nil)
      {
        file_path: file_path,
        chunk_type: chunk_type,
        identifier: identifier,
        content: content,
        language: language,
        start_line: start_line,
        end_line: end_line,
        content_hash: Digest::SHA256.hexdigest(content)
      }
    end

    def upsert_chunk(chunk_data)
      existing = project.code_chunks.find_by(
        file_path: chunk_data[:file_path],
        chunk_type: chunk_data[:chunk_type],
        identifier: chunk_data[:identifier]
      )

      if existing
        if existing.content_hash == chunk_data[:content_hash]
          @stats[:skipped] += 1
          return existing
        end

        existing.update!(
          content: chunk_data[:content],
          content_hash: chunk_data[:content_hash],
          language: chunk_data[:language],
          start_line: chunk_data[:start_line],
          end_line: chunk_data[:end_line],
          embedding: nil # Clear embedding so it gets regenerated
        )
        @stats[:indexed] += 1
        existing
      else
        project.code_chunks.create!(chunk_data)
        @stats[:indexed] += 1
      end
    end

    def remove_stale_chunks(current_paths)
      stale = project.code_chunks.where.not(file_path: current_paths)
      @stats[:removed] = stale.count
      stale.delete_all
    end

    def detect_language(file_path)
      case File.extname(file_path).downcase
      when ".rb" then "ruby"
      when ".js", ".jsx" then "javascript"
      when ".ts", ".tsx" then "typescript"
      when ".py" then "python"
      when ".go" then "go"
      when ".rs" then "rust"
      when ".md" then "markdown"
      end
    end

    def log_completion
      Rails.logger.info(
        message: "semantic_search.index_complete",
        project_id: project.id,
        indexed: stats[:indexed],
        skipped: stats[:skipped],
        removed: stats[:removed]
      )
    end
  end
end
