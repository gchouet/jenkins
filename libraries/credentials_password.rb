#
# Cookbook:: jenkins
# Resource:: credentials_password
#
# Author:: Seth Chisamore <schisamo@chef.io>
#
# Copyright:: 2013-2019, Chef Software, Inc.
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

require_relative 'credentials'
require_relative 'credentials_user'

class Chef
  class Resource::JenkinsPasswordCredentials < Resource::JenkinsUserCredentials
    resource_name :jenkins_password_credentials # Still needed for Chef 15 and below
    provides :jenkins_password_credentials

    # Attributes
    attribute :username,
              kind_of: String
    attribute :password,
              kind_of: String
  end
end

class Chef
  class Provider::JenkinsPasswordCredentials < Provider::JenkinsUserCredentials
    provides :jenkins_password_credentials

    def load_current_resource
      @current_resource ||= Resource::JenkinsPasswordCredentials.new(new_resource.name)

      super

      @current_resource.password(current_credentials[:password]) if current_credentials

      @current_resource
    end

    private

    #
    # @see Chef::Resource::JenkinsCredentials#credentials_groovy
    # @see https://github.com/jenkinsci/credentials-plugin/blob/master/src/main/java/com/cloudbees/plugins/credentials/impl/UsernamePasswordCredentialsImpl.java
    #
    def credentials_groovy
      <<-EOH.gsub(/^ {8}/, '')
        import com.cloudbees.plugins.credentials.*
        import com.cloudbees.plugins.credentials.impl.*

        credentials = new UsernamePasswordCredentialsImpl(
          CredentialsScope.GLOBAL,
          #{convert_to_groovy(new_resource.id)},
          #{convert_to_groovy(new_resource.description)},
          #{convert_to_groovy(new_resource.username)},
          #{convert_to_groovy(new_resource.password)}
        )
      EOH
    end

    #
    # @see Chef::Resource::JenkinsCredentials#attribute_to_property_map
    #
    def attribute_to_property_map
      { password: 'credentials.password.plainText' }
    end
  end
end
