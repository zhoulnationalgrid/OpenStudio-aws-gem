# NOTE: Do not modify this file as it is copied over. Modify the source file and rerun rake import_files
######################################################################
#  Copyright (c) 2008-2014, Alliance for Sustainable Energy.  
#  All rights reserved.
#  
#  This library is free software; you can redistribute it and/or
#  modify it under the terms of the GNU Lesser General Public
#  License as published by the Free Software Foundation; either
#  version 2.1 of the License, or (at your option) any later version.
#  
#  This library is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
#  Lesser General Public License for more details.
#  
#  You should have received a copy of the GNU Lesser General Public
#  License along with this library; if not, write to the Free Software
#  Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301  USA
######################################################################

######################################################################
# == Synopsis
#
#   Uses the aws-sdk gem to communicate with AWS
#
# == Usage
#
#  ruby aws.rb access_key secret_key us-east-1 EC2 launch_server "{\"instance_type\":\"t1.micro\"}"
#
#  ARGV[0] - Access Key
#  ARGV[1] - Secret Key
#  ARGV[2] - Region
#  ARGV[3] - Service (e.g. "EC2" or "CloudWatch")
#  ARGV[4] - Command (e.g. "launch_server")
#  ARGV[5] - Optional json with parameters associated with command
#
######################################################################

module OpenStudioAwsMethods
  def create_struct(instance, procs)
    instance_struct = Struct.new(:instance, :id, :ip, :dns, :procs)
    return instance_struct.new(instance, instance.instance_id, instance.public_ip_address, instance.public_dns_name, procs)
  end

  def find_processors(instance)
    processors = 1
    case instance
      when 'cc2.8xlarge'
        processors = 16
      when 'c1.xlarge'
        processors = 8
      when 'm2.4xlarge'
        processors = 8
      when 'm2.2xlarge'
        processors = 4
      when 'm2.xlarge'
        processors = 2
      when 'm1.xlarge'
        processors = 4
      when 'm1.large'
        processors = 2
      when 'm3.xlarge'
        processors = 2
      when 'm3.2xlarge'
        processors = 4
    end

    return processors
  end

  def launch_workers(num, server_ip)
    user_data = File.read(File.expand_path(File.dirname(__FILE__))+'/worker_script.sh.template')
    user_data.gsub!(/SERVER_IP/, server_ip)
    user_data.gsub!(/SERVER_HOSTNAME/, 'master')
    user_data.gsub!(/SERVER_ALIAS/, '')
    @logger.info("worker user_data #{user_data.inspect}")
    instances = []
    num.times do
      worker = @aws.instances.create(:image_id => @worker_image_id,
                                     :key_pair => @key_pair,
                                     :security_groups => @group,
                                     :user_data => user_data,
                                     :instance_type => @worker_instance_type)
      worker.add_tag('Name', :value => "OpenStudio-Worker V#{OPENSTUDIO_VERSION}")
      instances.push(worker)
    end
    sleep 5 while instances.any? { |instance| instance.status == :pending }
    if instances.any? { |instance| instance.status != :running }
      error(-1, "Worker status: Not running")
    end

    # todo: fix this - sometimes returns nil
    processors = find_processors(@worker_instance_type)
    #processors = send_command(instances[0].ip_address, 'nproc | tr -d "\n"')
    #processors = 0 if processors.nil?  # sometimes this returns nothing, so put in a default
    instances.each { |instance| @workers.push(create_struct(instance, processors)) }
  end

  def upload_file(host, local_path, remote_path)
    retries = 0
    begin
      Net::SCP.start(host, 'ubuntu', :key_data => [@private_key]) do |scp|
        scp.upload! local_path, remote_path
      end
    rescue SystemCallError, Timeout::Error => e
      # port 22 might not be available immediately after the instance finishes launching
      return if retries == 5
      retries += 1
      sleep 1
      retry
    rescue
      # Unknown upload error, retry
      return if retries == 5
      retries += 1
      sleep 1
      retry
    end
  end


  def send_command(host, command)
    #retries = 0
    begin
      output = ''
      Net::SSH.start(host, 'ubuntu', :key_data => [@private_key]) do |ssh|
        response = ssh.exec!(command)
        output += response if !response.nil?
      end
      return output
    rescue Net::SSH::HostKeyMismatch => e
      e.remember_host!
      # key mismatch, retry
      #return if retries == 5
      #retries += 1
      sleep 1
      retry
    rescue Net::SSH::AuthenticationFailed
      error(-1, "Incorrect private key")
    rescue SystemCallError, Timeout::Error => e
      # port 22 might not be available immediately after the instance finishes launching
      #return if retries == 5
      #retries += 1
      sleep 1
      retry
    rescue Exception => e
      puts e.message
      puts e.backtrace.inspect
    end
  end

#======================= send command ======================#
# Send a command through SSH Shell to an instance.
# Need to pass instance object and the command as a string.
  def shell_command(host, command)
    begin
      @logger.info("ssh_command #{command}")
      Net::SSH.start(host, 'ubuntu', :key_data => [@private_key]) do |ssh|
        channel = ssh.open_channel do |ch|
          ch.exec "#{command}" do |ch, success|
            raise "could not execute #{command}" unless success

            # "on_data" is called when the process writes something to stdout
            ch.on_data do |c, data|
              #$stdout.print data
              @logger.info("#{data.inspect}")
            end

            # "on_extended_data" is called when the process writes something to stderr
            ch.on_extended_data do |c, type, data|
              #$stderr.print data
              @logger.info("#{data.inspect}")
            end
          end
        end
      end
    rescue Net::SSH::HostKeyMismatch => e
      e.remember_host!
      @logger.info("key mismatch, retry")
      sleep 1
      retry
    rescue SystemCallError, Timeout::Error => e
      # port 22 might not be available immediately after the instance finishes launching
      sleep 1
      @logger.info("Not Yet")
      retry
    end
  end

  def wait_command(host, command)
    begin
      flag = 0
      while flag == 0 do
        @logger.info("wait_command #{command}")
        Net::SSH.start(host, 'ubuntu', :key_data => [@private_key]) do |ssh|
          channel = ssh.open_channel do |ch|
            ch.exec "#{command}" do |ch, success|
              raise "could not execute #{command}" unless success

              # "on_data" is called when the process writes something to stdout
              ch.on_data do |c, data|
                @logger.info("#{data.inspect}")
                if data.chomp == "true"
                  @logger.info("wait_command #{command} is true")
                  flag = 1
                else
                  sleep 5
                end
              end

              # "on_extended_data" is called when the process writes something to stderr
              ch.on_extended_data do |c, type, data|
                @logger.info("#{data.inspect}")
                if data == "true"
                  @logger.info("wait_command #{command} is true")
                  flag = 1
                else
                  sleep 5
                end
              end
            end
          end
        end
      end
    rescue Net::SSH::HostKeyMismatch => e
      e.remember_host!
      @logger.info("key mismatch, retry")
      sleep 1
      retry
    rescue SystemCallError, Timeout::Error => e
      # port 22 might not be available immediately after the instance finishes launching
      sleep 1
      @logger.info("Not Yet")
      retry
    end
  end

  def download_file(host, remote_path, local_path)
    retries = 0
    begin
      Net::SCP.start(host, 'ubuntu', :key_data => [@private_key]) do |scp|
        scp.download! remote_path, local_path
      end
    rescue SystemCallError, Timeout::Error => e
      # port 22 might not be available immediately after the instance finishes launching
      return if retries == 5
      retries += 1
      sleep 1
      retry
    rescue
      return if retries == 5
      retries += 1
      sleep 1
      retry
    end
  end
end
