module RedmineGitRemote
  module Patches
    module RepositoriesHelperPatch
      def self.included(base) # :nodoc:
        base.send(:include, InstanceMethods)
      end

      module InstanceMethods
        def git_remote_field_tags(form, repository)
          content_tag('p', 
            form.text_field(:url, :size => 60, :required => false, :disabled => !repository.safe_attribute?('url'), :label => l(:field_path_to_repository)) +
            content_tag('em', l(:text_git_remote_path_note), :class => 'info') +
            form.text_field(:extra_clone_url, :size => 60, :required => true, :disabled => !repository.safe_attribute?('url'), name: 'repository[extra_info][extra_clone_url]') +
            content_tag('em', l(:text_git_remote_url_note), :class => 'info') +
            form.text_area(:ssh_private_key, :required => false, :disabled => false, name: 'repository[extra_info][ssh_private_key]') +
            content_tag('em', l(:text_ssh_private_key), :class => 'info') +
            form.text_area(:ssh_public_key, :required => false, :disabled => false, name: 'repository[extra_info][ssh_public_key]') +
            content_tag('em', l(:text_ssh_public_key), :class => 'info')
          )
        end
      end
    end

    RepositoriesHelper.send(:include, RepositoriesHelperPatch)
  end
end