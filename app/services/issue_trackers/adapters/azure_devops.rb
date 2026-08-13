# frozen_string_literal: true

module IssueTrackers
  module Adapters
    class AzureDevops < Base
      def list_issues(filters: {})
        raise NotImplementedError, "#{self.class}#list_issues — Azure DevOps REST API integration pending"
      end

      def get_issue(external_id:)
        raise NotImplementedError, "#{self.class}#get_issue — Azure DevOps REST API integration pending"
      end

      def add_comment(external_id:, body:)
        raise NotImplementedError, "#{self.class}#add_comment — Azure DevOps REST API integration pending"
      end

      def update_status(external_id:, status:)
        raise NotImplementedError, "#{self.class}#update_status — Azure DevOps REST API integration pending"
      end

      def link_pr(external_id:, pr_url:, pr_title:)
        raise NotImplementedError, "#{self.class}#link_pr — Azure DevOps REST API integration pending"
      end

      def validate_connection!
        raise NotImplementedError, "#{self.class}#validate_connection! — Azure DevOps REST API integration pending"
      end
    end
  end
end
