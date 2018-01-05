#
# Cookbook Name :: solrcloud
# Library :: solrcloud_util
#
# A utility module to deal with helper methods.
#

module SolrCloud

  module Util

    require 'json'
    require 'net/http'
    require 'cgi'
    require 'rubygems'
    require 'excon'
    require 'fileutils'

    include Chef::Mixin::ShellOut
    include Solr::RestClient

    # Check if directory exists or not
    def directoryExists?(directory)
      File.directory?(directory)
    end

    # Downloads the default config from zookeeper
    def downloadDefaultConfig(solrversion,zkHost,configname, to_dir)
      begin
        Chef::Log.info("Remove the directory #{to_dir}.")
        FileUtils.rm_rf(to_dir)
        solrmajorversion = "#{solrversion}"[0,1]
        if "#{solrversion}".start_with? "4."
          solr_lib_path = "#{node['user']['dir']}/solr-war-lib"
        end
        solr_lib_path = "#{node['user']['dir']}/solr-war-lib#{solrmajorversion}"
        command = "java -classpath .:#{solr_lib_path}/* org.apache.solr.cloud.ZkCLI -cmd downconfig -zkhost #{zkHost} -confdir #{to_dir} -confname #{configname}"
        Chef::Log.info("downloadDefaultConfig command : #{command}")
        system "#{command}"
        Chef::Log.info("Successfully downloaded config '#{configname}'")
      rescue Exception => msg
        raise "Error while downloading zookeeper config : #{msg}"
      end
    end

    # Uploads the custom config to zookeeper
    def uploadCustomConfig(solrversion,zkHost,configname,dirname)
      Chef::Log.info("uploadCustomConfig : #{solrversion} : #{zkHost} : #{configname} : #{dirname}")
      solrmajorversion = "#{solrversion}"[0,1]
      begin
        solr_lib_path = ""
        if "#{solrversion}".start_with? "4."
          solr_lib_path = "#{node['user']['dir']}/solr-war-lib"
        end
        solr_lib_path = "#{node['user']['dir']}/solr-war-lib#{solrmajorversion}"
        command = "java -classpath .:#{solr_lib_path}/* org.apache.solr.cloud.ZkCLI -cmd upconfig -zkhost #{zkHost} -confdir #{dirname} -confname #{configname}"
        Chef::Log.info("uploadCustomConfig command : #{command}")
        bash 'upload_custom_config' do
          code <<-EOH
            #{command}
          EOH
        end
        Chef::Log.info("Successfully uploaded custom config '#{configname}'")
      rescue Exception => msg
        raise "Error while uploading zookeeper config : #{msg}"
      end
    end

    # Uploads the default config provided along with the solr package to zookeeper
    def uploadDefaultConfig(solrversion,zkHost,configname)
      dirname = "#{node['user']['dir']}/solr-config/default"
      if ("#{solrversion}".start_with? "5.") || ("#{solrversion}".start_with? "6.") || ("#{solrversion}".start_with? "7.")
        dirname = "#{node['installation_dir_path']}/solr#{solrmajorversion}/server/solr/configsets/data_driven_schema_configs/conf"
      end
      uploadCustomConfig(solrversion,zkHost,configname,dirname)
    end

    # Common api to send the collection admin api requests
    def solr_collection_api(host_name,port,params,config_name=nil,path="/solr/admin/collections")
      if not config_name.nil?
        path = "#{path}?".concat(params.collect { |k,v| "#{k}=#{CGI::escape(v.to_s)}" }.join('&'))+"&collection.configName="+config_name+"&wt=json"
      else
        path = "#{path}?".concat(params.collect { |k,v| "#{k}=#{CGI::escape(v.to_s)}" }.join('&'))+"&wt=json"
      end
      Chef::Log.info(" HostName = " + host_name + ", Port = " + port + ", Path = " + path)
      http = Net::HTTP.new(host_name, port)
      req = Net::HTTP::Get.new(path)

      unless !SolrAuth::AuthUtils.auth_enabled?
        admin_creds = SolrAuth::AuthUtils.get_solr_admin_credentials
        req.basic_auth(admin_creds['username'], admin_creds['password'])
      end
      response = http.request(req)
      if response != nil then
        return JSON.parse(response.body())
      end
      raise StandardError, "empty response"
    end

    # Extracts the custom configuration jar to a directory
    def extractCustomConfig(solr_config,config_jar,config_url,dir_name)

      # Create Directory "#{solr_config}/custom-tmp-dir"
      directory "#{solr_config}/#{dir_name}" do
        owner node['solr']['user']
        group node['solr']['user']
        mode '0777'
        action :create
      end

      # Extracts custom config jar
      bash 'unpack_customconfig_jar' do
        code <<-EOH
          cd #{solr_config}/#{dir_name}
          sudo rm -rf *.*
          sudo rm -rf */
          mv #{solr_config}/#{config_jar} #{solr_config}/#{dir_name}
          jar -xvf #{config_jar}
          sudo rm -rf #{config_jar}
        EOH
        not_if { "#{config_jar}".empty? }
      end
    end

    # sets the zookeeper FQDN connection string to zk_host_fqdns variable
    def setZkhostfqdn(zkselect,ci)
      cilocal = ci;
      if "#{zkselect}".include? "InternalEnsemble-SameAssembly"
        if "#{cilocal['platform_name']}".empty?
          raise "Zookeeper platform name should be provided for the selected option - InternalEnsemble-SameAssembly"
        end
        hostname = `hostname -f`
        fqdn = "#{hostname}".split('.')
        fqdn_string = "#{hostname}".split('.',6).last
        zk_host_fqdns = cilocal['platform_name']+"."+fqdn[1]+"."+fqdn[2]+"."+fqdn[3]+"."+fqdn_string
        node.set["zk_host_fqdns"] = zk_host_fqdns.strip;
      end

      if ("#{zkselect}".include? "ExternalEnsemble")
        zkp = cilocal['zk_host_fqdns']
        if "#{zkp}".empty?
          raise "External Zookeeper cluster fqdn connection string shoud be provided for the seleted option - ExternalEnsemble"
        end
        node.set["zk_host_fqdns"] = cilocal['zk_host_fqdns']
      end

      return node['zk_host_fqdns']
    end

    # Add replica on the given shard for given collection
    def addReplica(shard_name,collection_name)
      nodename = "#{node['ipaddress']}:#{node['port_no']}_solr"

      params = {:action => "ADDREPLICA",
      :collection => collection_name,:shard => shard_name,:node => nodename}

      jsonresponse = solr_collection_api(node['ipaddress'],node['port_no'],params)
      issuccess = jsonresponse.fetch('success', '')

      if issuccess.empty?
        iserror = jsonresponse.fetch('error', '')
        errormessage = iserror.fetch('msg','')
        raise errormessage
      else
        Chef::Log.info(issuccess)
      end
    end

    # Recover a node upon replace compute
    def replace_node_and_add_to_solrcloud(old_node_ip)
      Chef::Log.info( "***Old node IP  : #{old_node_ip}")
      Chef::Log.info( "***New node IP : #{node['ipaddress']}")

      computes = node.workorder.payLoad.has_key?("RequiresComputes") ? node.workorder.payLoad.RequiresComputes : node.workorder.payLoad.computes

      ipForUrl = ""

      # Get the compute IP which is not the replaced node IP
      computes.each do |compute|
        unless compute[:ciName].nil?
          if node["old_node_ip"] != compute[:ciAttributes][:private_ip]
            Chef::Log.info("IP to be used in the URLs to get the collections API  #{compute[:ciAttributes][:private_ip]}")
            ipForUrl = compute[:ciAttributes][:private_ip]
            break
          end
        end
      end

      portForUrl = ""

      if node["solr_version"].start_with? "4."
        portForUrl = "8080"
      else
        portForUrl = node['port_no']
      end

      solrCollectionUrl = "http://#{ipForUrl}:#{portForUrl}/solr/admin/collections?"

      # nodeip has new IP which has been set in default.rb. compare it with the node["old_node_ip"]
      ip_changed = node["old_node_ip"] != node['ipaddress']
      Chef::Log.info( " ip changed ? #{ip_changed} ")

      # If a node gets replaced and once the new IP is added to the live nodes do the ADDREPLICA and DELETEREPLICA

      # Get the cluster status
      clusterstatus_url = "#{solrCollectionUrl}action=CLUSTERSTATUS&wt=json"
      Chef::Log.info(" cluster status : #{clusterstatus_url}")
      clusterstatus_resp_obj = run_solr_action_api(clusterstatus_url)

      # Get the list of collections
      collectionslist_url = "#{solrCollectionUrl}action=LIST&wt=json"
      Chef::Log.info("collection : #{collectionslist_url}")
      collectionslist_resp_obj = run_solr_action_api(collectionslist_url)

      # Get the list of active IPs to make sure old ip doesn't exist there
      live_nodes = clusterstatus_resp_obj["cluster"]["live_nodes"]

      Chef::Log.info( "*** active_nodes : #{live_nodes}")

      # Get the list of collections from the LIST API
      collections = collectionslist_resp_obj['collections']
      Chef::Log.info( "*** collections from LIST api : #{collections}")

      # Get the json of collections from clusterstatus which includes shard and replica details
      cluster_status_collections = clusterstatus_resp_obj["cluster"]["collections"]

      # Find out the collections, shards and replicas that the old compute hold
      run_add_replica_delete_replica_for_new_node(collections, cluster_status_collections, solrCollectionUrl, portForUrl)

    end

    def run_add_replica_delete_replica_for_new_node(collections, cluster_status_collections, solrCollectionUrl, portForUrl)
      collections.each do |collection|
        Chef::Log.info( "*** Collection is : #{collection}")
        unless cluster_status_collections[collection]["shards"].nil?
          shard_names = cluster_status_collections[collection]["shards"].keys
          shards = cluster_status_collections[collection]["shards"]
          Chef::Log.info( "*** shard_names : #{shard_names}")
          shard_names.each do |shard|
            Chef::Log.info( "*** Shard is : #{shard}")
            unless shards[shard]["replicas"].nil?
              replica_names = shards[shard]["replicas"].keys
              replicas = shards[shard]["replicas"]
              Chef::Log.info( "*** replicas : #{replicas}")
              new_ip_exist = 0
              old_ip_exist = 0
              replica_names.each do |replica|
                Chef::Log.info( "*** Replica is : #{replica}")
                if replicas[replica]["base_url"].include? node["old_node_ip"]

                  old_ip_exist += 1
                  # Run ADDREPLICA and DELETEREPLICA for all the collections and shards associated with the old node
                  delete_replica_url = "#{solrCollectionUrl}action=DELETEREPLICA&collection=#{collection}&shard=#{shard}&replica=#{replica}"

                  Chef::Log.info("DELETEREPLICA : #{delete_replica_url}")
                  delete_replica_resp_obj = run_solr_action_api(delete_replica_url)
                  Chef::Log.info("Deleted old Replica : #{node['old_node_ip']}, for collection = #{collection} & shard = #{shard} & replica=#{replica}")
                else
                  Chef::Log.info("Skipping Delete Replica for the replica #{replica}")
                end

                # before adding the replica check if the new node ip is part of any collection in the cluster state, if so then don't do it
                # new-IP exists and old-IP too exists - Deletes the replica and sets old_ip_exist = 1, sets new_ip_exist = 1 => No add replica
                # new-IP exists and old-IP does not - doesn't delete replica, old_ip_exist = 0, sets new_ip_exist = 1 => No add replica
                # new-IP does not exist and old IP does - Deletes the replica and sets old_ip_exist = 1, new_ip_exist = 0 => Satisfies the condition for add replica
                if replicas[replica]["base_url"].include? node['ipaddress']
                  Chef::Log.info("New IP #{node['ipaddress']} is found in the Replica for collection = #{collection} & shard = #{shard}")
                  new_ip_exist += 1
                else
                  Chef::Log.info("New IP #{node['ipaddress']} is not found in replicas of collection = #{collection} & shard = #{shard}")
                end
              end
              # if old IP existed and new IP is not shown fire addreplica
              if (old_ip_exist > 0 && new_ip_exist == 0)
                add_replica_url = "#{solrCollectionUrl}action=ADDREPLICA&collection=#{collection}&shard=#{shard}&node=#{node['ipaddress']}:#{portForUrl}_solr"
                Chef::Log.info("ADDREPLICA: #{add_replica_url}")
                add_replica_resp_obj = run_solr_action_api(add_replica_url)
                Chef::Log.info("Added new Replica : #{node['ipaddress']}, for collection = #{collection} & shard = #{shard}")
              else
                Chef::Log.info("Skipping Add Replica for collection = #{collection} & shard = #{shard}, since value of old_ip_exist=#{old_ip_exist} and value of new_ip_exist=#{new_ip_exist}")
              end
            end
          end
        end
      end
    end

    def run_solr_action_api(url)
      conn = Excon.new(
          url,
          :headers => {
              'Content-Type' => 'application/json'
          },
          :ssl_verify_peer => false)

      response = conn.request(:method=>'GET')
      response_body = response.body
      status = response.status
      Chef::Log.info( "*** HTTP Status of #{url}: #{status} ")
      begin
        resp_obj = JSON.parse(response_body)
        return resp_obj

      rescue JSON::ParserError => e
        Chef::Log.info( "HTTP response : #{response_body}")
        if status != 200
          Chef::Log.error("Solr Collections API returned an error #{response_body}")
          exit 1
        end
      end
    end

    # Common api to send core admin requests
    def solr_core_api(host_name,port,params,path="/solr/admin/cores")
      path = "#{path}?".concat(params.collect { |k,v| "#{k}=#{CGI::escape(v.to_s)}" }.join('&'))+"&wt=json"
      Chef::Log.info(" HostName = " + host_name + ", Port = " + port + ", Path = " + path)
      http = Net::HTTP.new(host_name, port)
      req = Net::HTTP::Get.new(path)
      unless !SolrAuth::AuthUtils.auth_enabled?
        admin_creds = SolrAuth::AuthUtils.get_solr_admin_credentials
        req.basic_auth(admin_creds['username'], admin_creds['password'])
      end
      response = http.request(req)
      if response != nil then
        return JSON.parse(response.body())
      end
      raise StandardError, "empty response"
    end

    # Validate the given shard name
    # Input : shard_name
    def validateShardName(shard_name)
      shardStringIndex = shard_name.index('shard')
      if shardStringIndex.nil?
        raise "Invalid shard name provided"
      else
        shardNo = shard_name[shardStringIndex+5,shard_name.length-1]
        isShardNoInteger = Integer(shardNo) rescue false

        if not isShardNoInteger
          raise "Invalid shard no is provided"
        end
      end
    end

    # To check the collection exists in the given collection list.
    # Input : collection_name, collection_list
    # Output : status
    def isCollectionExists(collection_name,collection_list)
      collection_list.each do |collection|
        if collection_name == collection
          return true
        end
      end
      return false
    end

    # Get collections on that compute
    # Output : collection_list
    def get_cluster_collections
      params = {:action => "LIST"}
      cluster_collections = solr_collection_api(node['ipaddress'], node['port_no'], params)
      collection_list = cluster_collections["collections"]
      return collection_list
    end

    # Get cores on that compute
    # Output : core_list
    def get_node_solr_cores
      params = {:action => "STATUS"}
      node_solr_cores = solr_core_api(node['ipaddress'], node['port_no'], params)
      return node_solr_cores["status"].keys
    end

    # Get the clusterstatus for solr higher versions(5.x/6.x etc.,)
    def clusterStatusV6(host_name,port,collection_name,path="/solr/admin/zookeeper",params="detail=true&path=/collections/")
      path = "#{path}?#{params}"+"#{collection_name}/state.json&wt=json"
      Chef::Log.info(" HostName = " + host_name + ", Port = " + port + ", Path = " + path)
      http = Net::HTTP.new(host_name, port)
      req = Net::HTTP::Get.new(path)
      unless !SolrAuth::AuthUtils.auth_enabled?
        admin_creds = SolrAuth::AuthUtils.get_solr_admin_credentials
        req.basic_auth(admin_creds['username'], admin_creds['password'])
      end
      response = http.request(req)
      if response != nil then
        return JSON.parse(response.body())
      end
      raise StandardError, "empty response"
    end

    # Delete replica on the given shard for given collection
    def deleteReplica(shard_name,collection_name,replica)
      params = {:action => "DELETEREPLICA",
      :collection => collection_name,:shard => shard_name,:replica => replica}

      jsonresponse = solr_collection_api(node['ipaddress'],node['port_no'],params)
      issuccess = jsonresponse.fetch('success', '')

      if issuccess.empty?
        iserror = jsonresponse.fetch('error', '')
        errormessage = iserror.fetch('msg','')
        raise errormessage
      else
        Chef::Log.info(issuccess)
      end
    end

    # Create the symlink between the mount point in cinder volume and the data directory
    def create_symlink_from_data_to_cinder_mountpoint()

      # Chef::Log.info("#{node['data_dir_path']}/data/ is empty.")
      if node.has_key?("cinder_volume_mountpoint") && !node["cinder_volume_mountpoint"].empty?
        Chef::Log.info("Cinder storage is enabled for the data directory at the mount point #{node["cinder_volume_mountpoint"]}")

        parent_data_dir = node['data_dir_path']
        data_dir = "#{parent_data_dir}/data"
        # Ruby Block
        ruby_block 'create_data_symlink' do
          block do
            # Check if the data symlink exists.
            if !File.symlink?(data_dir)

              Chef::Log.warn("data symlink doesn't exist in #{parent_data_dir}.")
              if File.directory?(data_dir)
                raise "#{data_dir} is a directory. It is supposed to be a symlink while using with Cinder. You cannot include Cinder storage if you were using Ephemeral with the first deployment"
              else
                Chef::Log.info("neither data directory nor data symlink exist in #{parent_data_dir}.")
              end
            else
              Chef::Log.info("data symlink exists in #{parent_data_dir}.")
              data_link_path = File.readlink(data_dir)
              Chef::Log.info("Data symlink points to #{data_link_path}")

              if data_link_path != node["cinder_volume_mountpoint"]
                raise "#{data_dir} is not linked to #{node["cinder_volume_mountpoint"]}. It is supposed to be a symlink while using with Cinder."
              end
            end
          end
        end

        # Provide a symlink from the /app/solrdata<version>/data to the Cinder mount point
        Chef::Log.info("Provide a symlink from the #{data_dir} to the Cinder mount point #{node["cinder_volume_mountpoint"]}")
        link "#{node['data_dir_path']}/data" do
          to "#{node["cinder_volume_mountpoint"]}"
          owner node['solr']['user']
          group node['solr']['user']
        end

        bash 'chown_blockstorage' do
          code <<-EOH
            sudo chown #{node['solr']['user']} /#{node["cinder_volume_mountpoint"]}
            sudo chgrp #{node['solr']['user']} /#{node["cinder_volume_mountpoint"]}
          EOH
          not_if { "#{node["cinder_volume_mountpoint"]}".empty? }
        end

      else
        Chef::Log.info("Cinder storage is not enabled. So the following scripts will create the data directory in the ephemeral storage.")
      end

    end

    # Find the configuration directory structure and verify whether it has the required configuration files(like: solrconfig.xml, managed-schema/schema.xml) 
    # and directories (like: lang)
    # Validate and upload the contents of solr configuration jar file.
    def validate_and_upload_config_jar_contents(custom_dir_full_path, config_name)
      Dir.chdir("#{custom_dir_full_path}")
      Chef::Log.info("current directory - [#{Dir.getwd}]")
      solrconfig_files = File.join("**","solrconfig.xml")
      possible_subdirs = Array.new()
      Dir.glob(solrconfig_files).each do |solrconfig_file|
        Chef::Log.info("Find parent directory for the file #{solrconfig_file}")
        parent_dir = File.dirname(solrconfig_file)
        Dir.chdir("#{parent_dir}")
        important_objects = 0
        Chef::Log.info("parent directory - [#{Dir.getwd}]")
        if Dir.glob(File.join("managed-schema")).empty?
          if Dir.glob(File.join("schema.xml")).empty?
            Chef::Log.warn("Neither schema.xml nor managed-schema file is present. Cannot upload this configuration to zookeeper.")
          else
            schema_file_name = "schema.xml"
            important_objects += 1
            Chef::Log.info("schema.xml file is present")
          end
        else
          schema_file_name = "managed-schema"
          important_objects += 1
          Chef::Log.info("managed-schema file is present")
          if parent_dir == "."
            validate_schema_fields("#{custom_dir_full_path}/#{schema_file_name}")
          else
            validate_schema_fields("#{custom_dir_full_path}/#{parent_dir}/#{schema_file_name}")
          end
        end
        # if Dir.glob(File.join("META-INF")).empty?
        #   Chef::Log.warn("META-INF directory does not exist.")
        # else
        #   important_objects += 1
        #   Chef::Log.info("META-INF directory exists in the directory - [#{parent_dir}]")
        # end
        # File.join("**","lang", "**") -- Check whether lang directory has some files. This returns empty when the lang directory do not contain files and also if it is present as a file.
        # So, In case if it returns empty then logs an message and will not consider the parent directory as a valid directory.
        # if Dir.glob(File.join("**","lang", "**")).empty?
        #   Chef::Log.warn("lang directory is empty.")
        # else
        #   important_objects += 1
        #   Chef::Log.info("lang directory exists in the directory - [#{parent_dir}]")
        # end
        if (important_objects == 1)
          Chef::Log.info("Found all required configration file in the directory -- #{parent_dir}")
          possible_subdirs.push(parent_dir)
        end
        Dir.chdir("#{custom_dir_full_path}")
      end
      if (possible_subdirs.length == 0)
        Chef::Log.raise("No directory found that contains Solr's configuration files like solrconfig.xml etc. Cannot upload to zookeeper")
      end
      if (possible_subdirs.length > 1)
        Chef::Log.raise("Several directories found that contains Solr's configuration files like solrconfig.xml etc. Cannot determine which one to upload to zookeeper. [ #{possible_subdirs} ]")
      end
      node.set['config_sub_dir'] = "#{possible_subdirs[0]}"

      if node['config_sub_dir'] == "."
        Chef::Log.info("java -classpath .:#{node['user']['dir']}/solr-war-lib#{node['solr_version'][0,1]}/* org.apache.solr.cloud.ZkCLI -cmd upconfig -zkhost #{node['zk_host_fqdns']} -confdir #{custom_dir_full_path} -confname #{config_name}")
        system "java -classpath .:#{node['user']['dir']}/solr-war-lib#{node['solr_version'][0,1]}/* org.apache.solr.cloud.ZkCLI -cmd upconfig -zkhost #{node['zk_host_fqdns']} -confdir #{custom_dir_full_path} -confname #{config_name}"
      else
        Chef::Log.info("java -classpath .:#{node['user']['dir']}/solr-war-lib#{node['solr_version'][0,1]}/* org.apache.solr.cloud.ZkCLI -cmd upconfig -zkhost #{node['zk_host_fqdns']} -confdir #{custom_dir_full_path}/#{node['config_sub_dir']} -confname #{config_name}")
        system "java -classpath .:#{node['user']['dir']}/solr-war-lib#{node['solr_version'][0,1]}/* org.apache.solr.cloud.ZkCLI -cmd upconfig -zkhost #{node['zk_host_fqdns']} -confdir #{custom_dir_full_path}/#{node['config_sub_dir']} -confname #{config_name}"
      end
    end

    def collections_exists_on_cluster(ip_address, port_no)
      begin
        http = Net::HTTP.new(ip_address, port_no)
        resp = nil
        http.start do |http|
          req = Net::HTTP::Get.new("/solr/admin/collections?action=LIST&wt=json")
          unless !SolrAuth::AuthUtils.auth_enabled?
            admin_creds =  SolrAuth::AuthUtils.get_solr_admin_credentials
            req.basic_auth(admin_creds['username'], admin_creds['password'])
          end
          resp, data = http.request(req)
        end

        if resp != nil then
          if resp.code == "200"
            response_body = resp.body()
            resp_obj = JSON.parse(response_body)
            collection_list = resp_obj["collections"]
            if (collection_list != nil) && (!collection_list.empty?)
              return true
            else
              return false
            end
          else
            puts "Solr API returned an error #{resp.body()}"
            return false
          end
        end
      rescue
        return false
      end
    end
    
    def validate_schema_fields(schema_file_path)
      file = File.new(schema_file_path)
      xml_doc = REXML::Document.new(file)
      xml_doc.elements.each("schema/field") do |element|

        if element.attributes["name"] == "_version_"
          Chef::Log.error("Field \"_version_\" must be of type long otherwise Solr may fail to read indexes") if element.attributes["type"].downcase != "long"
          # If attribute is not specified, assume it using default value as specified in
          # https://lucene.apache.org/solr/guide/6_6/field-type-definitions-and-properties.html#field-default-properties
          indexed     = (element.attributes['indexed']     == nil)?true:  (element.attributes['indexed'].downcase == "true")
          stored      = (element.attributes['stored']      == nil)?true:  (element.attributes['stored'].downcase == "true")
          docValues   = (element.attributes['docValues']   == nil)?false: (element.attributes['docValues'].downcase == "true")
          multiValued = (element.attributes['multiValued'] == nil)?false: (element.attributes['multiValued'].downcase == "true")

          # See getAndCheckVersionField() in https://github.com/apache/lucene-solr/blob/master/solr/core/src/java/org/apache/solr/update/VersionInfo.java
          Chef::Log.error("Field \"_version_\" should either be indexed or have docValues true.") if (!indexed && !docValues)
          Chef::Log.error("Field \"_version_\" should either be stored or have docValues true.") if (!stored && !docValues)
          Chef::Log.error("Field \"_version_\" should not be multiValued.") if (multiValued)
          Chef::Log.info("Validated version field.")
        end
      end
    end

   #This method returns all solr cloud instances for the given action
   #Payload has all the solrcloud instances . for ex. from 3 clouds, If only 1 cloud selected for replace and if there are 3 computes/cloud so actually
   #in the workorder there will 9 solrclouds with 3 having action='replace' and other with action=null
   def get_solrcloud_instances_by_action(node, action)
     if !node['workorder']['payLoad'].has_key?("SolrClouds")
       puts "***FAULT:FATAL=SolrClouds payload not found, you must pull the design."
       e = Exception.new("no backtrace")
       e.set_backtrace("")
       raise e  
     end
     solr_clouds = node['workorder']['payLoad']['SolrClouds']
     Chef::Log.info("Total solrcloud instances in the payload : #{solr_clouds.size()}")
     solr_clouds_actioned =  solr_clouds.select { |solr_cloud|  solr_cloud['rfcAction'] != nil && solr_cloud['rfcAction'].eql?(action) }
     Chef::Log.info("Total solrcloud instances with action #{action} in the deployment : #{solr_clouds_actioned.size()}")
     return solr_clouds_actioned
   end

   # get map of compute index/no & private_ip. ex. {"34951930-1"=>"private_ip", "34951930-2"=>"private_ip", "34951930-3"=>"private_ip"}
   def get_compute_number_to_ip_map(node)
     compute_number_to_ip_map = Hash.new()
     computes = node['workorder']['payLoad'].has_key?("RequiresComputes") ? node['workorder']['payLoad']['RequiresComputes'] : node['workorder']['payLoad']['computes']
     computes.each do |compute|
       #extract compute number from compute name ex. compute-34951930-1 => "34951930-1"
       compute_number = compute['ciName'].split('-',2)[1]
       compute_number_to_ip_map[compute_number] =  compute['ciAttributes']['private_ip']
     end
     return compute_number_to_ip_map
   end

   # returns map of cloudId and deployment order
   # ex {34951930=>"1", 35709237=>"2", 34951924=>"3"}
   def cloud_deployment_order(node)
     if !node.workorder.payLoad.has_key?("CloudPayload")
       puts "***FAULT:FATAL=Clouds payload not found, you must pull the design."
       e = Exception.new("no backtrace")
       e.set_backtrace("")
       raise e  
     end
     clouds = node.workorder.payLoad.CloudPayload
     #create a map of cloudId & deployment order for each cloud in the deployment.
     cloud_id_dpmt_order_map = Hash.new()
     clouds.each do |cloud|
       #consider only 'active' clouds (there might be some cloud which are shutdown/ignored so don't consider them)
       next if cloud.ciAttributes.adminstatus != 'active'
       #get user provided deployment order for cloud, if not available, defaults to 0
       # here key cloud['ciId']=> cloudId for each cloud in the cloud payload (ex. 35709237) & 'base.Consumes.dpmt_order' => deployment order
       cloud_number = cloud['ciId']
       cloud_deployment_order = cloud['ciAttributes']['base.Consumes.dpmt_order']
       cloud_id_dpmt_order_map[cloud_number] = cloud_deployment_order != nil ? cloud_deployment_order : "0"
     end
     return cloud_id_dpmt_order_map
   end

  # get the cluster status. Keep reading status until time exceeds provided  'timeout' sec in case of TIMEOUT error
  def get_cluster_state(host, port, timeout_sec)
    params = {
        :action => "CLUSTERSTATUS"
    }
    cluster_state = nil
    sleep_time_sec = 10
    attempts = timeout_sec/sleep_time_sec
    success = false
    while attempts >= 0 do
      begin
        Chef::Log.info("Getting cluster status. Remaining attempts : #{attempts}")
        attempts = attempts - 1
        cluster_status_resp = solr_collection_api(host, port, params)
        cluster_state = cluster_status_resp["cluster"]
        success = true
        break
      rescue => e
        Chef::Log.info("Error while getting cluster status : #{e.message}")
        Chef::Log.info("Retry getting cluster status after #{sleep_time_sec} seconds")
        sleep sleep_time_sec
      end
    end
    if !success
      error = "Could not fetch the cluster state in #{timeout_sec} seconds"
      puts "***FAULT:FATAL=#{error}"
      raise error
    end
    return cluster_state
  end
  
  # Verify if the given nodes ips are live
  def nodes_live?(host, port, ip_list, timeout_sec)
    params = {
        :action => "CLUSTERSTATUS"
    }
    sleep_time_sec = 10
    attempts = timeout_sec/sleep_time_sec
    all_nodes_live = false
    while attempts >= 0 do
      begin
        live_nodes = []
        Chef::Log.info("Getting live nodes. Remaining attempts : #{attempts}")
        attempts = attempts - 1
        cluster_status_resp = solr_collection_api(host, port, params)
        cluster_live_nodes = cluster_status_resp["cluster"]["live_nodes"]
        cluster_live_nodes.each do |live_node|
          ipaddress = live_node.split(":")[0]
          live_nodes.push ipaddress
        end
        Chef::Log.info("live_nodes = #{live_nodes}")
        result = (ip_list-live_nodes)
        if result.empty?
          all_nodes_live = true
          break
        else
          Chef::Log.info("Nodes not live : #{result}")
        end
      rescue => e
        Chef::Log.info("Error while getting live nodes : #{e.message}")
        Chef::Log.info("Retry getting live nodes after #{sleep_time_sec} seconds")
        sleep sleep_time_sec
      end
    end
    return all_nodes_live
  end
  
  # Verify that all the prior nodes in the workorder are live
  def verify_prior_nodes_live(node)
    if node.workorder.has_key?("rfcCi")
      ci = node.workorder.rfcCi
      actionName = node.workorder.rfcCi.rfcAction
    else
      ci = node.workorder.ci
      actionName = node.workorder.actionName
    end
    
    timeout_sec = node['solr_api_timeout_sec'].to_i
    
    #get the map with all cloud's id & deployment order in the form |key,value| => |cloudId, deployment_order|
    #ex {34951930=>"7", 35709237=>"8", 34951924=>"4"}
    cloudIdsWithDpmtOrderMap = cloud_deployment_order(node)
    Chef::Log.info("Cloud id & deployment order map : #{cloudIdsWithDpmtOrderMap.to_json}")
  
    #get array of solrcloud nodes for the action selected
    #get list of all solrcloud nodes which are selected for this action in the deployment
    nodesInAction = get_solrcloud_instances_by_action(node, actionName)
  
    thisNodeCiName = ci[:ciName]
    Chef::Log.info("This solrcloud node's ciName : #{thisNodeCiName}")
  
    #get the node cloud id "solrcloud-34951924-1" => "34951924"
    thisCloudId = thisNodeCiName.split('-')[1]
  
    #get the deployment order of this node's cloud
    thisNodeCloudDpmtOrder = cloudIdsWithDpmtOrderMap.fetch(thisCloudId.to_i)
    Chef::Log.info("This node's cloud deployment order : #{thisNodeCloudDpmtOrder}")
  
    #get all cloud ids having deployment order <= node_cloud_deployment_order. This is required to make sure that all prior cloud deployment was completed
    #ex From all clouds {34951930=>"7", 35709237=>"8", 34951924=>"4"} for node_cloud_deployment_order = 7 => {34951930=>"7", 34951924=>"4"}
    #same node_cloud_id is inclusive because there may be multiple nodes in node's cloud.
    #This list is used to make sure that all nodes across this cloud list are deployed first
    cloudIdsTobeDeployedPrior = []
    cloudIdsWithDpmtOrderMap.each do |k, v|
      if v.to_i <= thisNodeCloudDpmtOrder.to_i
        cloudIdsTobeDeployedPrior.push k
      end
    end
    Chef::Log.info("Cloud ids to be deployed before : #{cloudIdsTobeDeployedPrior.to_json}")
  
    #get solrcloud nodes for cloud ids to be deployed prior
    nodeIndexesTobeDeployedPrior = []
    nodesInAction.each do |n|
      ciName = n['ciName']
      cloudId = ciName.split('-')[1]
      index = ciName.split('-', 2)[1]
      if cloudIdsTobeDeployedPrior.include? cloudId.to_i
        # prefx the cloud deployment order to determine the order of solr instace in the deployment
        # User might select the lower cloudId with higher deployment order and vice-versa so deployment order will be useful
        nodeIndexesTobeDeployedPrior.push cloudIdsWithDpmtOrderMap[cloudId.to_i]+"-"+index
      end
    end
  
    #sort solrcloud_nodes_tobe_deployed_prior by ciName (cloudId & compute index)
    nodeIndexesTobeDeployedPrior.sort! {|a, b| b <=> a}
    #default sorting is in descending order, we want to process the deployment in the ascending order of compute number
    #so reverse the order
    nodeIndexesTobeDeployedPrior.reverse!
    Chef::Log.info("solrclouds to executed before #{nodeIndexesTobeDeployedPrior.to_json}")
  
    computeCloudIdIpMap = get_compute_number_to_ip_map(node)
    Chef::Log.info("compute number to ip map : #{computeCloudIdIpMap.to_json}")
    # prefx the cloud deployment order to determine the order of solr instace in the deployment
    # User might select the lower cloudId with higher deployment order and vice-versa so deployment order will be useful
    thisNodeIndex = thisNodeCloudDpmtOrder+"-"+thisNodeCiName.split('-',2)[1]
    Chef::Log.info("This node index : #{thisNodeIndex}")
  
    # select only the nodes with lower index & this node index
    nodeIndexesTobeDeployedPrior = nodeIndexesTobeDeployedPrior.select {|cloudIdIndex| cloudIdIndex <= thisNodeIndex}
  
    index = nodeIndexesTobeDeployedPrior.index {|id| id == thisNodeIndex}
    Chef::Log.info("index = #{index}")
  
    wait_time = index * 10;
    Chef::Log.info("Allowing #{wait_time} seconds for prior nodes to start the deployment before")
    sleep wait_time
  
    nodeIpsTobeDeployedPrior = []
    nodeIndexesTobeDeployedPrior.each do |nodeIndex|
      if !nodeIndex.eql? thisNodeIndex
        nodeIndexWithoutDpmtOrder = nodeIndex.split('-',2)[1]
        Chef::Log.info("nodeIndexWithoutDpmtOrder = #{nodeIndexWithoutDpmtOrder}")
        nodeIpsTobeDeployedPrior.push computeCloudIdIpMap[nodeIndexWithoutDpmtOrder]
      end
    end
  
    # No need to check for other nodes to confirm those are live before processing this node as there are no prior nodes in the list
    if nodeIpsTobeDeployedPrior.empty?
      return
    end
  
    Chef::Log.info("nodeIpsTobeDeployedPrior = #{nodeIpsTobeDeployedPrior.to_json}")
    host = nodeIpsTobeDeployedPrior[0]
    cluster_state = get_cluster_state(host, node['port_no'], timeout_sec)
    nodes_up_status = nodes_live?(host, node['port_no'], nodeIpsTobeDeployedPrior, timeout_sec)
    Chef::Log.info("Node live status : #{nodes_up_status}")
    if !nodes_up_status 
      error = "Some of the prior nodes from list #{nodeIpsTobeDeployedPrior.to_json} in the deployment are not live."
      puts "***FAULT:FATAL=#{error}"
      raise error
    end
  end
  
  # get map of cloudId as key & list of compute ip as value
  # Ex. {"34951924":["private_ip1","private_ip2"],"34951930":["private_ip3","private_ip4"],"35709237":["private_ip5","private_ip6"]}
  def get_cloudid_to_compute_ip_map(node)
    cloudid_to_compute_ip_map = Hash.new()
    computes = node['workorder']['payLoad'].has_key?("RequiresComputes") ? node['workorder']['payLoad']['RequiresComputes'] : node['workorder']['payLoad']['computes']
    computes.each do |compute|
      cloudId = compute['ciName'].split('-',3)[1]
      if !cloudid_to_compute_ip_map.has_key?cloudId
        cloudid_to_compute_ip_map[cloudId] = []
      end
      cloudid_to_compute_ip_map[compute['ciName'].split('-',3)[1]].push compute['ciAttributes']['private_ip']
    end
    return cloudid_to_compute_ip_map
  end

  # returns true if any of the attribute has changed
  def update_found(node)
    old_vals = node.workorder.rfcCi.ciBaseAttributes
    new_vals = node.workorder.rfcCi.ciAttributes
    new_vals.keys.each do |k|
      if old_vals.has_key?(k) && 
         old_vals[k] != new_vals[k]
         Chef::Log.info("changed: old #{k}:#{old_vals[k]} != new #{k}:#{new_vals[k]}")
         return true
      end
    end
    return false
  end
  end
end
