# frozen_string_literal: true

module ClarifyingQuestions
  class OpenChat
    def self.call(...)
      new(...).call
    end

    def initialize(issue:, user:)
      @issue = issue
      @user = user
    end

    def call
      return open_legacy_chat unless feature_conversation?
      return open_feature_chat unless existing_feature_chat

      reuse_feature_chat(existing_feature_chat)
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    private

    attr_reader :issue, :user

    # @spec QUESTION-EXPLORATION-018
    # The RDR-069 rollout setting gates only the feature-conversation path.
    # Standalone issues and projects that never enabled exploration keep the
    # legacy per-issue canonical chat.
    def feature_conversation?
      issue.project.question_exploration_enabled? && feature.present?
    end

    def feature
      @feature ||= issue.feature_intent
    end

    def open_legacy_chat
      existing_chat || open_new_chat
    end

    # @spec QUESTION-EXPLORATION-001
    def existing_chat
      chat = ChatSession.where(clarifying_question_issue: issue).order(updated_at: :desc).first
      return unless chat

      ChatSessions::Unarchive.call(chat_session: chat) if chat.archived?
      chat.update!(title:) unless chat.title == title
      chat
    end

    # The pending questions are resolved before ChatSessions::Create opens its
    # insert transaction: ClarifyingQuestions::Load performs GitHub I/O (its
    # reconcile path can even post to GitHub), which must never hold a
    # database connection or the partial unique index's insert while it runs.
    # The resolved questions are snapshotted into session metadata so the
    # system prompt renders them without another network round trip.
    # @spec QUESTION-EXPLORATION-001
    def open_new_chat
      questions = ClarifyingQuestions::Load.call(project: issue.project, issue: issue)
      ChatSessions::Create.call(
        account: issue.project.account,
        user: user,
        project_id: issue.project_id,
        title:,
        metadata: {
          "clarifying_question_issue_id" => issue.id,
          "clarifying_questions" => questions
        },
        clarifying_question_issue: issue
      )
    end

    # @spec QUESTION-EXPLORATION-018
    def existing_feature_chat
      @existing_feature_chat ||= ChatSession.where(feature_intent: feature).order(updated_at: :desc, id: :desc).first
    end

    def open_feature_chat
      adoptable_chat ? adopt_feature_chat(adoptable_chat) : open_new_feature_chat
    end

    def reuse_feature_chat(chat)
      ChatSessions::Unarchive.call(chat_session: chat) if chat.archived?
      focus_chat(chat)
      chat.update!(title: feature_title) unless chat.title == feature_title
      chat
    end

    # A pre-existing per-issue linked chat for one of the feature's issues is
    # adopted into the feature conversation instead of forking context. The
    # chat linked to the opening issue wins; otherwise the most recently
    # updated chat for another feature issue.
    # @spec QUESTION-EXPLORATION-018
    def adoptable_chat
      scope = ChatSession.where(feature_intent_id: nil)
        .where(clarifying_question_issue_id: feature.issues.select(:id))
        .order(updated_at: :desc, id: :desc)
      scope.where(clarifying_question_issue_id: issue.id).first || scope.first
    end

    def adopt_feature_chat(chat)
      ChatSessions::Unarchive.call(chat_session: chat) if chat.archived?
      chat.update!(feature_intent: feature, title: feature_title)
      focus_chat(chat)
      chat
    end

    def open_new_feature_chat
      questions = ClarifyingQuestions::Load.call(project: issue.project, issue: issue)
      ChatSessions::Create.call(
        account: issue.project.account,
        user: user,
        project_id: issue.project_id,
        title: feature_title,
        metadata: {
          "clarifying_question_issue_id" => issue.id,
          "clarifying_questions" => questions,
          "exploration_focus" => focus_metadata(questions)
        },
        clarifying_question_issue: issue,
        feature_intent: feature
      )
    end

    # Focuses the conversation on the opened issue. Same-issue repeats only
    # refresh the snapshot; moving to another feature issue appends a system
    # notice carrying the newly focused questions so the running transcript
    # stays truthful, and never repoints the conversation's linkage.
    # @spec QUESTION-EXPLORATION-018
    def focus_chat(chat)
      questions = ClarifyingQuestions::Load.call(project: issue.project, issue: issue)
      metadata = chat.metadata || {}
      current_focus_id = chat.exploration_focus&.dig("issue_id") || chat.clarifying_question_issue_id
      return if current_focus_id == issue.id && metadata["clarifying_questions"] == questions

      append_focus_notice(chat, questions) unless current_focus_id == issue.id
      chat.update!(metadata: metadata.merge(
        "clarifying_questions" => questions,
        "exploration_focus" => focus_metadata(questions)
      ))
    end

    def append_focus_notice(chat, questions)
      chat.messages.create!(role: "system", content: <<~TEXT.strip)
        The conversation now focuses on the clarifying questions for #{issue.project.full_name}##{issue.github_number}: #{issue.title}
        #{questions.each_with_index.map { |question, index| "#{index + 1}. #{question}" }.join("\n")}
      TEXT
    end

    def focus_metadata(questions)
      {
        "issue_id" => issue.id,
        "questions" => questions,
        "focused_by_id" => user.id,
        "focused_at" => Time.current.iso8601
      }
    end

    def title
      "Clarifying questions for #{issue.project.full_name}##{issue.github_number}"
    end

    def feature_title
      "Feature exploration for #{issue.project.full_name}: #{feature.title}"
    end
  end
end
