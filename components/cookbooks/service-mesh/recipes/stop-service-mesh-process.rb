Chef::Log.info("Stopping service mesh...")
execute 'startServiceMesh' do
	command "#{node['service-mesh']['init-name']} stop"
	user	'root'
	returns [0,1]
end
Chef::Log.info("Service mesh stopped successfully.")
