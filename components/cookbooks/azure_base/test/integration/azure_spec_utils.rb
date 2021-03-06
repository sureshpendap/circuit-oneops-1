require '/opt/oneops/inductor/circuit-oneops-1/components/cookbooks/azure_base/test/integration/spec_utils'

class AzureSpecUtils < SpecUtils
  def initialize(node)
    @node = node
  end

  def get_azure_creds
    cloud_name = get_cloud_name
    app_type = get_app_type
    svc = get_service

    credentials = {
        tenant_id: svc['tenant_id'],
        client_secret: svc['client_secret'],
        client_id: svc['client_id'],
        subscription_id: svc['subscription']
    }

    credentials
  end
  def get_resource_group_name
    nsPathParts = get_ns_path_parts
    org = nsPathParts[1]
    assembly = nsPathParts[2]
    environment = nsPathParts[3]

    svc = get_service
    location = svc['location']

    resource_group_name = org[0..15] + '-' + assembly[0..15] + '-' + @node['workorder']['box']['ciId'].to_s + '-' + environment[0..15] + '-' + Utils.abbreviate_location(location)
    resource_group_name
  end
  def set_attributes_on_node_required_for_vm_manager
    @node.set['image_id'] = get_image_id
    @node.set['platform-resource-group'] = get_resource_group_name
  end
  def is_express_route_enabled
    svc = get_service

    express_route_enabled = true
    if svc[:express_route_enabled].nil?
      # We cannot assume express route is enabled if it is not set
      express_route_enabled = false
    elsif svc[:express_route_enabled] == 'false'
      express_route_enabled = false
    end

    express_route_enabled
  end
  def get_azure_rule_definition(resource_group_name, network_security_group_name, rules, node)
    sec_rules = []
    priority = 100
    reg_ex = /(\d+|\*|\d+-\d+)\s(\d+|\*|\d+-\d+)\s([A-Za-z]+|\*)\s\S+/
    rules.each do |item|
      raise "#{item} is not a valid security rule" unless reg_ex.match(item)
      item2 = item.split(' ')
      security_rule_access = Fog::ARM::Network::Models::SecurityRuleAccess::Allow
      security_rule_description = node['secgroup']['description']
      security_rule_source_addres_prefix = item2[3]
      security_rule_destination_port_range = item2[1].to_s
      security_rule_direction = Fog::ARM::Network::Models::SecurityRuleDirection::Inbound
      security_rule_priority = priority
      security_rule_protocol = case item2[2].downcase
        when 'tcp'
          Fog::ARM::Network::Models::SecurityRuleProtocol::Tcp
        when 'udp'
          Fog::ARM::Network::Models::SecurityRuleProtocol::Udp
        else
          Fog::ARM::Network::Models::SecurityRuleProtocol::Asterisk
        end
      security_rule_provisioning_state = nil
      security_rule_destination_addres_prefix = '*'
      security_rule_source_port_range = '*'
      security_rule_name = network_security_group_name + '-' + priority.to_s
      sec_rules << { name: security_rule_name, resource_group: resource_group_name, protocol: security_rule_protocol, network_security_group_name: network_security_group_name, source_port_range: security_rule_source_port_range, destination_port_range: security_rule_destination_port_range, source_address_prefix: security_rule_source_addres_prefix, destination_address_prefix: security_rule_destination_addres_prefix, access: security_rule_access, priority: security_rule_priority, direction: security_rule_direction }
      priority += 100
      end
    sec_rules
  end

  def get_traffic_manager_profile_name
    ns_path_parts = get_ns_path_parts
    traffic_manager_profile_name = 'trafficmanager-' + ns_path_parts[5]

    traffic_manager_profile_name
  end

  def get_remote_gdns
    remote_gdns = @node['workorder']['payLoad']['remotegdns']

    remote_gdns
  end

  def get_traffic_manager_routing_method
    remote_gdns = get_remote_gdns
    routing_method = remote_gdns[0]['ciAttributes']['traffic-routing-method']

    routing_method
  end

  def get_traffic_manager_ttl
    remote_gdns = get_remote_gdns
    ttl = remote_gdns[0]['ciAttributes']['ttl']

    ttl
  end

  def get_application_gateway_name
    "ag-#{@node['workorder']['box']['ciName'].gsub(/-/, '').downcase}"
  end

  def get_vm_count
    @node['workorder']['payLoad']['DependsOn'].count
  end

  def get_vm_private_ip_addresses
    ip_addresses = []
    @node['workorder']['payLoad']['DependsOn'].each do |vm_data|
      ip_addresses << vm_data['ciAttributes']['private_ip']
    end
    ip_addresses
  end

  # Converts the hash given by the node according to the new syntax
  def get_dns_attributes
    cloud_name = get_cloud_name
    dns_attributes = @node['workorder']['services']['dns'][cloud_name]['ciAttributes']

    dns_attributes_hash = get_azure_creds
    dns_attributes_hash[:subscription] = dns_attributes_hash[:subscription_id]
    dns_attributes_hash[:zone] = dns_attributes['zone']
    dns_attributes_hash[:cloud_dns_id] = dns_attributes['cloud_dns_id']

    dns_attributes_hash.delete :subscription_id
    dns_attributes_hash
  end

  # Returns name of a DNS record
  def get_record_set_name
    ns_path_parts = get_ns_path_parts
    org = ns_path_parts[1]
    assembly = ns_path_parts[2]
    environment = ns_path_parts[3]
    ci_name = @node['workorder']['box']['ciName']

    dns_attributes = get_dns_attributes

    record_set_name = "#{ci_name}.#{environment}.#{assembly}.#{org}.#{dns_attributes[:cloud_dns_id]}"
    record_set_name.downcase!
    record_set_name
  end

  # Gets public IPs of all VMs deployed
  def get_all_vms_public_ips
    ip_addresses = []
    @node['workorder']['payLoad']['RequiresComputes'].each do |vm_data|
      ip_addresses << vm_data['ciAttributes']['public_ip']
    end
    ip_addresses
  end

  # Get public IP of the LB deployed
  def get_lb_public_ip
    lb_ip_address = []
    @node['workorder']['payLoad']['lb'].each do |lb_data|
      lb_ip_address << lb_data['ciAttributes']['dns_record']
    end

    lb_ip_address
  end

  # checks the existence of load balancer in the deployment
  def lb_exists?
    $node['workorder']['payLoad'].key?('lb')
  end

  def is_imagetypecustom
    cloud_name = @node[:workorder][:cloud][:ciName]
    cloud = @node[:workorder][:services][:compute][cloud_name][:ciAttributes]
    os = nil
    ostype = "default-cloud"
    if @node[:workorder][:payLoad].has_key?("os")
      os = @node[:workorder][:payLoad][:os].first
      ostype = os[:ciAttributes][:ostype]
    else
      Chef::Log.warn("missing os payload - using default-cloud")
      if ostype == "default-cloud"
        ostype = cloud[:ostype]
      end
    end
    imagemap = JSON.parse( cloud[:imagemap] )
    image_id = ''
    if !os.nil? && os[:ciAttributes].has_key?("image_id") && !os[:ciAttributes][:image_id].empty?
      image_id = os[:ciAttributes][:image_id]
    else
      image_id = imagemap[ostype]
    end

    imagidcustom = image_id.split(':')
    imagidcustom.eql? 'Custom'
  end
end
