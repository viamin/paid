# frozen_string_literal: true

module ClarifyingQuestions
  class IngestAnswers
    ARTIFACT_TYPE = "qa_pair"
    COLLECTOR_TYPE = "clarifying_question_answers"

    def self.call(project:, issue:, issue_comments: nil, issue_body: nil, answers: nil)
      new(
        project: project,
        issue: issue,
        issue_comments: issue_comments,
        issue_body: issue_body,
        answers: answers
      ).call
    end

    def initialize(project:, issue:, issue_comments: nil, issue_body: nil, answers: nil)
      @project = project
      @issue = issue
      @injected_comments = issue_comments
      @issue_body = issue_body
      @answers = answers
    end

    def call
      return unless github_available?

      extraction = extract_pairs
      qa_pairs = extraction.qa_pairs
      return if qa_pairs.empty?

      ingest(qa_pairs, extraction.answer_comment)
    rescue GithubClient::Error
      nil
    end

    private

    attr_reader :project, :issue, :issue_body, :answers

    def github_available?
      project.github_credential_present?
    end

    def github_client
      @github_client ||= project.client
    end

    # Resolves the qa pairs and their source comment from one of three
    # channels: a pre-parsed answers payload (description channel),
    # a description body carrying an answers section (description channel,
    # no comment fetch), or the comment channel. Each path runs through
    # the same ExtractAnswerPairs contract so the knowledge-base writes
    # converge.
    def extract_pairs
      return payload_extraction if @answers
      return body_extraction if @issue_body

      ExtractAnswerPairs.call(project: project, issue_comments: issue_comments, issue: issue)
    end

    def payload_extraction
      current_questions = Array(@answers[:questions])
      parsed_pairs = Array(@answers[:parsed_pairs])
      return empty_result if current_questions.empty? || parsed_pairs.empty?

      paired = pair_qa(current_questions, parsed_pairs)
      ExtractAnswerPairs::Result.new(qa_pairs: paired, answer_comment: nil)
    end

    def body_extraction
      section = DescriptionSection.parse_answers(@issue_body)
      return empty_result unless section

      current_questions = DescriptionSection.parse_questions(@issue_body).questions
      current_questions = Array(issue.respond_to?(:needs_input_questions) ? issue.needs_input_questions : []) if current_questions.empty?
      current_questions = current_questions.presence || []
      parsed_pairs = AnswerPairs.parse(section[:inner].to_s)
      return empty_result unless AnswerPairs.questions_match?(current_questions, parsed_pairs)

      ExtractAnswerPairs::Result.new(
        qa_pairs: pair_qa(current_questions, parsed_pairs),
        answer_comment: nil
      )
    end

    def empty_result
      ExtractAnswerPairs::Result.new(qa_pairs: [], answer_comment: nil)
    end

    def issue_comments
      @issue_comments ||= begin
        comments = @injected_comments || github_client.issue_comments(project.full_name, issue.github_number)
        comments.select { |comment| CommentAdmission.admissible?(project: project, comment: comment) }
      end
    end

    def ingest(qa_pairs, answer_comment)
      ActiveRecord::Base.transaction do
        project_version = find_or_create_project_version!
        collector_run = find_or_create_collector_run!(project_version)

        qa_pairs.each do |qa|
          ingest_qa_pair!(qa, answer_comment, collector_run)
        end

        collector_run.mark_completed!(count: qa_pairs.size)
      end
    end

    def ingest_qa_pair!(qa_pair, answer_comment, collector_run)
      content = "Q: #{qa_pair[:question]}\nA: #{qa_pair[:answer]}"
      content_hash = Digest::SHA256.hexdigest(content)

      return if KnowledgeChunk.for_project(project).exists?(chunk_type: ARTIFACT_TYPE, content_hash: content_hash)

      identifier = "qa_pair:#{issue.github_number}:#{content_hash[0..11]}"
      scope_path = "clarifying_questions/#{project.full_name}/issues/#{issue.github_number}"

      artifact = KnowledgeArtifact.create!(
        project: project,
        collector_run: collector_run,
        artifact_type: ARTIFACT_TYPE,
        collector_type: COLLECTOR_TYPE,
        scope_path: scope_path,
        identifier: identifier,
        content: content,
        content_hash: content_hash,
        metadata: {
          issue_id: issue.id,
          issue_number: issue.github_number,
          comment_id: answer_comment&.id,
          question: qa_pair[:question],
          source: answer_comment ? "comment" : "description"
        },
        status: "active"
      )

      artifact.knowledge_chunks.create!(
        project: project,
        chunk_type: "qa_pair",
        content: content,
        content_hash: content_hash,
        scope_tags: [ "qa_pair", "issue_#{issue.github_number}" ],
        sequence: 0,
        status: "active"
      )
    end

    def pair_qa(questions, parsed_pairs)
      questions.each_with_index.filter_map do |question, index|
        answer = parsed_pairs[index]&.fetch(:answer, nil)
        next if answer.blank?

        { question: question, answer: answer }
      end
    end

    def find_or_create_project_version!
      latest = project.project_versions.by_recency.first
      return latest if latest

      project.project_versions.create!(
        commit_sha: "0" * 40,
        branch: project.default_branch || "main"
      )
    end

    def find_or_create_collector_run!(project_version)
      existing = project_version.collector_runs.find_by(collector_type: COLLECTOR_TYPE)
      if existing
        existing.mark_running!
        return existing
      end

      project_version.collector_runs.create!(
        collector_type: COLLECTOR_TYPE,
        status: "running",
        started_at: Time.current
      )
    end
  end
end
