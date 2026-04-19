# frozen_string_literal: true

module IssueTrackers
  module Adapters
    class GithubIssues < Base
      def list_issues(filters: {})
        raise NotImplementedError, "#{self.class}#list_issues — delegate to existing GitHub sync"
      end

      def get_issue(external_id:)
        raise NotImplementedError, "#{self.class}#get_issue — delegate to existing GitHub sync"
      end

      def add_comment(external_id:, body:)
        raise NotImplementedError, "#{self.class}#add_comment — delegate to existing GitHub client"
      end

      def update_status(external_id:, status:)
        raise NotImplementedError, "#{self.class}#update_status — delegate to existing GitHub client"
      end

      def link_pr(external_id:, pr_url:, pr_title:)
        raise NotImplementedError, "#{self.class}#link_pr — delegate to existing GitHub client"
      end

      def validate_connection!
        true
      end
    end
  end
end
