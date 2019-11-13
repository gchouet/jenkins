#
# Cookbook:: jenkins
# Resource:: jnlp_slave
#
# Author:: Seth Chisamore <schisamo@chef.io>
#
# Copyright:: 2013-2017, Chef Software, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require_relative 'slave'

class Chef
  class Resource::JenkinsJnlpSlave < Resource::JenkinsSlave
    resource_name :jenkins_jnlp_slave

    # Actions
    actions :create, :delete, :connect, :disconnect, :online, :offline
    default_action :create

    # Attributes
    attribute :group,
              kind_of: String,
              default: 'jenkins',
              regex: Config[:group_valid_regex]
    attribute :service_name,
              kind_of: String,
              default: 'jenkins-slave'
    attribute :supplementary_groups,
              kind_of: Array,
              default: []
  end
end

class Chef
  class Provider::JenkinsJnlpSlave < Provider::JenkinsSlave
    use_inline_resources # ~FC113
    provides :jenkins_jnlp_slave

    def load_current_resource
      @current_resource ||= Resource::JenkinsJnlpSlave.new(new_resource.name)

      super
    end

    action :create do
      do_create

      declare_resource(:directory, ::File.expand_path(new_resource.remote_fs, '..')) do
        recursive(true)
        action :create
      end

      unless Chef::Platform.windows?
        declare_resource(:group, new_resource.group) do
          system(node['jenkins']['master']['use_system_accounts'])
        end

        declare_resource(:user, new_resource.user) do
          gid(new_resource.group)
          comment('Jenkins slave user - Created by Chef')
          home(new_resource.remote_fs)
          system(node['jenkins']['master']['use_system_accounts'])
          action :create
        end
      end

      declare_resource(:directory, new_resource.remote_fs) do
        owner(new_resource.user)
        group(new_resource.group)
        recursive(true)
        action :create
      end

      declare_resource(:remote_file, slave_jar).tap do |r|
        # We need to use .tap() to access methods in the provider's scope.
        r.source slave_jar_url
        r.backup(false)
        r.mode('0755')
        r.atomic_update(false)
        r.notifies :restart, "runit_service[#{new_resource.service_name}]" unless Chef::Platform.windows?
      end

      # The Windows's specific child class manages it's own service
      return if Chef::Platform.windows?

      include_recipe 'runit'

      service_resource
    end

    action :delete do
      # Stop and remove the service
      service_resource.run_action(:disable)

      do_delete
    end

    private

    #
    # @see Chef::Resource::JenkinsSlave#launcher_groovy
    # @see http://javadoc.jenkins-ci.org/hudson/slaves/JNLPLauncher.html
    #
    def launcher_groovy
      'launcher = new hudson.slaves.JNLPLauncher()'
    end

    #
    # The path (url) of the slave's unique JNLP file on the Jenkins
    # master.
    #
    # @return [String]
    #
    def jnlp_url
      @jnlp_url ||= uri_join(endpoint, 'computer', new_resource.slave_name, 'slave-agent.jnlp')
    end

    #
    # Generates the slaves unique JNLP secret using the Groovy API.
    #
    # @return [String]
    #
    def jnlp_secret
      return @jnlp_secret if @jnlp_secret
      json = executor.groovy! <<-EOH.gsub(/ ^{8}/, '')
        output = [
          secret:jenkins.slaves.JnlpSlaveAgentProtocol.SLAVE_SECRET.mac('#{new_resource.slave_name}')
        ]

        builder = new groovy.json.JsonBuilder(output)
        println(builder)
      EOH
      output = JSON.parse(json, symbolize_names: true)
      @jnlp_secret = output[:secret]
    end

    #
    # The url of the +slave.jar+ on the Jenkins master.
    #
    # @return [String]
    #
    def slave_jar_url
      @slave_jar_url ||= uri_join(endpoint, 'jnlpJars', 'slave.jar')
    end

    def service_resource
      declare_resource(:runit_service, new_resource.service_name).tap do |r|
        # We need to use .tap() to access methods in the provider's scope.
        r.cookbook('jenkins')
        r.run_template_name('jenkins-slave')
        r.log_template_name('jenkins-slave')
        r.options(
          service_name: new_resource.service_name,
          jvm_options: new_resource.jvm_options,
          user:        new_resource.user,
          remote_fs:   new_resource.remote_fs,
          java_bin:    java,
          slave_jar:   slave_jar,
          jnlp_url:    jnlp_url,
          jnlp_secret: jnlp_secret
        )
      end
    end

    #
    # The checksum of the +slave.jar+.
    #
    # @return [String]
    #
    def slave_jar_checksum
      @slave_jar_checksum ||= new_resource.checksum
    end

    #
    # The path to the +slave.jar+ on disk (which may or may not exist).
    #
    # @return [String]
    #
    def slave_jar
      ::File.join(new_resource.remote_fs, 'slave.jar')
    end

    # Embedded Resources

    #
    # Creates a `group` resource that represents the system group
    # specified the `group` attribute. The caller will need to call
    # `run_action` on the resource.
    #
    # @return [Chef::Resource::Group]
    #
    def group_resource
      @group_resource ||= build_resource(:group, new_resource.group) do
        system(node['jenkins']['master']['use_system_accounts']) # ~FC048 this is a foodcritic bug
      end
    end

    #
    # Creates a `user` resource that represents the system user
    # specified the `user` attribute. The caller will need to call
    # `run_action` on the resource.
    #
    # @return [Chef::Resource::User]
    #
    def user_resource
      @user_resource ||= build_resource(:user, new_resource.user) do
        gid(new_resource.group)
        comment('Jenkins slave user - Created by Chef')
        home(new_resource.remote_fs)
        system(node['jenkins']['master']['use_system_accounts']) # ~FC048 this is a foodcritic bug
      end
    end

    #
    # Creates the parent `directory` resource that is a level above where
    # the actual +remote_fs+ will live. This is required due to a Chef/RedHat
    # bug where +--create-home-dir+ behavior changed and broke the Internet.
    #
    # @return [Chef::Resource::Directory]
    #
    def parent_remote_fs_dir_resource
      @parent_remote_fs_dir_resource ||=
        begin
          path = ::File.expand_path(new_resource.remote_fs, '..')
          build_resource(:directory, path) do
            recursive(true)
          end
        end
    end

    #
    # Creates a `directory` resource that represents the directory
    # specified the `remote_fs` attribute. The caller will need to call
    # `run_action` on the resource.
    #
    # @return [Chef::Resource::Directory]
    #
    def remote_fs_dir_resource
      @remote_fs_dir_resource ||= build_resource(:directory, new_resource.remote_fs) do
        owner(new_resource.user)
        group(new_resource.group)
        recursive(true)
      end
    end

    #
    # Creates a `remote_file` resource that represents the remote
    # +slave.jar+ file on the Jenkins master. The caller will need to
    # call `run_action` on the resource.
    #
    # @return [Chef::Resource::RemoteFile]
    #
    def slave_jar_resource
      @slave_jar_resource ||=
        begin
          build_resource(:remote_file, slave_jar).tap do |r|
            # We need to use .tap() to access methods in the provider's scope.
            r.source slave_jar_url
            r.checksum slave_jar_checksum
            r.backup(false)
            r.mode('0755')
            r.atomic_update(false)
          end
        end
    end

    #
    # Returns a fully configured service resource that can start the
    # JNLP slave process. The caller will need to call `run_action` on
    # the resource.
    #
    # @return [Chef::Resource::RunitService]
    #
    def service_resource
      @service_resource ||=
        begin
          # Ensure runit is installed on the slave.
          include_recipe 'runit'

          build_resource(:runit_service, new_resource.service_name).tap do |r|
            # We need to use .tap() to access methods in the provider's scope.
            r.cookbook('jenkins')
            r.run_template_name('jenkins-slave')
            r.log_template_name('jenkins-slave')
            r.options(
              new_resource: new_resource,
              java_bin:     java,
              slave_jar:    slave_jar,
              jnlp_url:     jnlp_url,
              jnlp_secret:  jnlp_secret,
              user:         new_resource.user,
              groups:       new_resource.supplementary_groups.empty? ? [] : [new_resource.group] + new_resource.supplementary_groups
            )
          end
        end
    end
  end
end
