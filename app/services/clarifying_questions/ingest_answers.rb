# frozen_string_literal: true

module ClarifyingQuestions
  class IngestAnswers
    ARTIFACT_TYPE = "qa_pair"
    COLLECTOR_TYPE = "clarifying_question_answers"

    def self.call(project:, issue:, issue_comments: nil)
      new(project: project, issue: issue, issue_comments: issue_comments).call
    end

    def initialize(project:, issue:, issue_comments: nil)
      @project = project
      @issue = issue
      @injected_comments = issue_comments
    end

    def call
      return unless github_available?

      enhancement_comment = find_enhancement_comment
      return unless enhancement_comment

      answer_comment = find_answer_comment
      return unless answer_comment
      return unless answer_newer_than_enhancement?(answer_comment, enhancement_comment)

      questions = Parse.call(comment_body: enhancement_comment.body.to_s)
      return if questions.empty?

      answers = parse_answers(answer_comment.body.to_s)
      return if answers.empty?

      qa_pairs = pair_qa(questions, answers)
      return if qa_pairs.empty?

      ingest(qa_pairs, answer_comment)
    rescue GithubClient::Error
      nil
    end

    private

    attr_reader :project, :issue

    def github_available?
      project.github_token.present?
    end

    def github_client
      @github_client ||= project.github_token.client
    end

    def find_enhancement_comment
      issue_comments.reverse.find do |comment|
        body = comment.body.to_s
        body.include?(Parse::ENHANCEMENT_MARKER) &&
          body.include?("## Clarifying questions")
      end
    end

    def find_answer_comment
      issue_comments.reverse.find do |comment|
        comment.body.to_s.include?(Load::ANSWER_MARKER)
      end
    end

    def answer_newer_than_enhancement?(answer_comment, enhancement_comment)
      answer_time = answer_comment.created_at&.to_time || Time.at(0)
      enhancement_time = enhancement_comment.created_at&.to_time || Time.at(0)
      answer_time > enhancement_time
    end

    def issue_comments
      @issue_comments ||= begin
        comments = @injected_comments || github_client.issue_comments(project.full_name, issue.github_number)
        comments.select { |comment| trusted_comment?(comment) }
      end
    end

    def trusted_comment?(comment)
      project.trusted_github_user?(comment.user&.login)
    end

    def parse_answers(body)
      body.scan(/\*\*A\d+:\*\*\s*(.+?)(?=\n\n\*\*|\z)/m).map { |m| m[0].strip }
    end

    def pair_qa(questions, answers)
      questions.each_with_index.filter_map do |question, i|
        next if answers[i].blank?

        { question: question, answer: answers[i] }
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
          comment_id: answer_comment.id,
          question: qa_pair[:question]
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
