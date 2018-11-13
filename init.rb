require 'redmine'
require_dependency "redmine_git_remote/repositories_helper_patch"

Redmine::Scm::Base.add "GitRemote"

Redmine::Plugin.register :redmine_git_remote do
  name 'Redmine Git Remote'
  author 'Alex Dergachev'
  url 'https://github.com/dergachev/redmine_git_remote'
  description 'Automatically clone and fetch remote git repositories'
  version '0.0.1'
  settings  :partial => 'settings/redmine_git_remote', 
            :default => {
              'clones_root_directory': 'files/redmine_git_remote/repositories',
              'keys_root_directory': 'files/redmine_git_remote/keys'
            }
end
