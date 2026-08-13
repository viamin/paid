# frozen_string_literal: true

class ChangeAutoFixMergeConflictsDefaultOnProjects < ActiveRecord::Migration[8.1]
  def change
    change_column_default :projects, :auto_fix_merge_conflicts, from: false, to: true
  end
end
