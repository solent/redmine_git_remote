require 'redmine/scm/adapters/git_adapter'
require 'pathname'
require 'fileutils'
# require 'open3'
require_dependency 'redmine_git_remote/poor_mans_capture3'

class Repository::GitRemote < Repository::Git

  PLUGIN_ROOT = Pathname.new(__FILE__).join("../../../..").realpath.to_s
  PATH_PREFIX = Setting.plugin_redmine_git_remote["clones_root_directory"] + "/"
  KEYS_PREFIX = Setting.plugin_redmine_git_remote["keys_root_directory"] + "/"
  
  before_validation :initialize_clone

  safe_attributes 'extra_info', :if => lambda {|repository, _user| repository.new_record?}

  # TODO: figure out how to do this safely (if at all)
  # before_deletion :rm_removed_repo
  # def rm_removed_repo
  #   if Repository.find_all_by_url(repo.url).length <= 1
  #     system "rm -Rf #{self.clone_path}"
  #   end
  # end

  def extra_clone_url
    return nil unless extra_info
    extra_info["extra_clone_url"]
  end

  def clone_url
    self.extra_clone_url
  end

  def clone_path
    self.url
  end

  def clone_host
    p = parse(clone_url)
    return p[:host]
  end

  def ssh_public_key
    return nil unless extra_info
    extra_info["ssh_public_key"]
  end

  def ssh_private_key
    return nil unless extra_info
    extra_info["ssh_private_key"]
  end

  def ssh_key_dir
    return "#{KEYS_PREFIX}/#{self.clone_host}"
  end

  def ssh_private_key_path
    return "#{self.ssh_key_dir}/#{self.identifier}.key"
  end

  def ensure_ssh_private_key_exists
    unless File.file?( self.ssh_private_key_path )
      begin
        FileUtils.mkdir_p self.ssh_key_dir
      rescue Exception => e
        raise "Failed to create directory #{self.ssh_key_dir}: " + e.to_s
      end
      begin
        File.open( ssh_private_key_path, "w") { |file| file.write( self.ssh_private_key ) }
      rescue Exception => e
        raise "Failed to write SSH private key to #{self.ssh_private_key_path}: " + e.to_s
      end
    end

    begin
      # Mandatory if we want SSH to use that private key (else SSH fails with permissions warning on stderr)
      system "chmod", "600", self.ssh_private_key_path
    rescue Exception => e
      raise "Failed to setup permissions on '#{self.ssh_private_key_path}': " + e.to_s
    end
  end

  def git_ssh_command
    self.ensure_ssh_private_key_exists
    return "ssh -F /dev/null -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -i #{self.ssh_private_key_path}"
  end

  def git_env
    if clone_protocol_ssh?
      return { "GIT_SSH_COMMAND" => "#{self.git_ssh_command}" }
    else
      return {}
    end
  end

  def clone_protocol_ssh?
    # Possible valid values (via http://git-scm.com/book/ch4-1.html):
    #  ssh://user@server/project.git
    #  user@server:project.git
    #  server:project.git
    # For simplicity we just assume if it's not HTTP(S), then it's SSH.
    !clone_url.match(/^http/)
  end

  # Hook into Repository.fetch_changesets to also run 'git fetch'.
  def fetch_changesets
    # ensure we don't fetch twice during the same request
    return if @already_fetched
    @already_fetched = true

    puts "Calling fetch changesets on #{clone_path}"
    # runs git fetch
    self.fetch
    super
  end

  # Override default_branch to fetch, otherwise caching problems in
  # find_project_repository prevent Repository::Git#fetch_changesets from running.
  #
  # Ideally this would only be run for RepositoriesController#show.
  def default_branch
    if self.branches == [] && self.project.active? && Setting.autofetch_changesets?
      # git_adapter#branches caches @branches incorrectly, reset it
      scm.instance_variable_set :@branches, nil
      # NB: fetch_changesets is idemptotent during a given request, so OK to call it 2x
      self.fetch_changesets
    end
    super
  end

  # called in before_validate handler, sets form errors
  def initialize_clone
    # avoids crash in RepositoriesController#destroy
    return unless attributes["extra_info"]["extra_clone_url"]

    p = parse(attributes["extra_info"]["extra_clone_url"])
    self.identifier = p[:identifier] if identifier.empty?
    self.url = PATH_PREFIX + p[:path] if url.empty?

    err = ensure_possibly_empty_clone_exists
    errors.add :extra_clone_url, err if err
  end

  # equality check ignoring trailing whitespace and slashes
  def two_remotes_equal(a,b)
    a.chomp.gsub(/\/$/,'') == b.chomp.gsub(/\/$/,'')
  end

  def execute_git_command(*args)
    git_command = args.unshift( "git" )
    #logger.info "Git env: #{self.git_env.to_s}"
    #logger.info "Git command: #{git_command.join(' ')}"
    return system self.git_env, *git_command
  end

  def capture_git_command(*args)
    git_command = args.unshift( "git" )
    return RedmineGitRemote::PoorMansCapture3::capture2(self.git_env, *git_command)
  end

  def ensure_possibly_empty_clone_exists
    Repository::GitRemote.add_known_host(clone_host) if clone_protocol_ssh?

    output, status = capture_git_command("ls-remote",  "-h",  clone_url)
    #logger.info "git ls-remote output: '#{output}'."
    #logger.info "git ls-remote status: '#{status}'."
    return "#{clone_url} is not a valid remote or SSH public key is not allowed to access it." unless status.success?

    if Dir.exists? clone_path
      existing_repo_remote, status = capture_git_command("--git-dir", clone_path, "config", "--get", "remote.origin.url")
      return "Unable to run: git --git-dir #{clone_path} config --get remote.origin.url" unless status.success?

      unless two_remotes_equal(existing_repo_remote, clone_url)
        return "Directory '#{clone_path}' already exists, but with a different remote url: #{existing_repo_remote}."
      end
    else
      unless execute_git_command "init", "--bare", clone_path
        return  "Unable to run: git init --bare #{clone_path}"
      end

      unless execute_git_command "--git-dir", clone_path, "remote", "add", "--mirror=fetch", "origin",  clone_url
        return  "Unable to run: git --git-dir #{clone_path} remote add --mirror=fetch origin #{clone_url}"
      end
    end
  end

  unloadable
  def self.scm_name
    'GitRemote'
  end

  # TODO: first validate git URL and display error message
  def parse(url)
    url.strip!

    ret = {}
    # start with http://github.com/evolvingweb/git_remote or git@git.ewdev.ca:some/repo.git
    ret[:url] = url

    # NB: Starting lines with ".gsub" is a syntax error in ruby 1.8.
    #     See http://stackoverflow.com/q/12906048/9621
    # path is github.com/evolvingweb/muhc-ci
    ret[:path] = url.gsub(/^.*:\/\//, '').   # Remove anything before ://
                     gsub(/:/, '/').         # convert ":" to "/"
                     gsub(/^.*@/, '').       # Remove anything before @
                     gsub(/\.git$/, '')      # Remove trailing .git
    ret[:host] = ret[:path].split('/').first
    #TODO: handle project uniqueness automatically or prompt
    ret[:identifier] =   ret[:path].split('/').last.downcase.gsub(/[^a-z0-9_-]/,'-')
    return ret
  end

  def fetch
    puts "Fetching repo #{clone_path}"
    Repository::GitRemote.add_known_host(clone_host) if clone_protocol_ssh?

    err = ensure_possibly_empty_clone_exists
    Rails.logger.warn err if err

    # If dir exists and non-empty, should be safe to 'git fetch'
    unless execute_git_command "--git-dir", clone_path, "fetch", "--all"
      Rails.logger.warn "Unable to run 'git -c #{clone_path} fetch --all'"
    end
  end

  def self.add_known_host(host)
    
    # if not found...
    #out, status = RedmineGitRemote::PoorMansCapture3::capture2("ssh-keygen", "-F", host)
    #raise "Unable to run 'ssh-keygen -F #{host}" unless status
    #unless out.match /found/
      # hack to work with 'docker exec' where HOME isn't set (or set to /)
    #  ssh_dir = (ENV['HOME'] == "/" || ENV['HOME'] == nil ? "/root" : ENV['HOME']) + "/.ssh"
    #  ssh_known_hosts = ssh_dir + "/known_hosts"
    #  begin
    #    FileUtils.mkdir_p ssh_dir
    #  rescue Exception => e
    #    raise "Unable to create directory #{ssh_dir}: " + e.to_s
    #  end

    #  puts "Adding #{host} to #{ssh_known_hosts}"
    #  out, status = RedmineGitRemote::PoorMansCapture3::capture2("ssh-keyscan", host)
    #  raise "Unable to run 'ssh-keyscan #{host}'" unless status
    #  Kernel::open(ssh_known_hosts, 'a') { |f| f.puts out}
    #end
  end
end
