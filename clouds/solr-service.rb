# Solr global configuration cloud service.
# This service is used to provide the solr custom configurations. This service should be added as cloud service for all the clouds which are being used in the transition.
# In solrcloud & solr-collection cookbook will use this service to access various custom configurations defined as attributes
name 'solr-service'
description 'Solr Service'
auth 'solrsecretkey'

service 'solr-service',
        :description => 'Solr custom configuration',
        :cookbook => 'solr-service',
        :source => Chef::Config[:register],
        :provides => {:service => 'solr-service'},
        :attributes => {
            :solr_custom_params => '{
              "block_expensive_queries_class": "com.walmart.strati.search.solr.BlockExpensiveQueries",
              "slow_query_logger_class": "com.walmart.strati.search.solr.SlowQueryLogger",
              "query_source_tracker_class": "com.walmart.strati.search.solr.QuerySourceTracker",
              "solr_dosfilter_class": "com.walmart.strati.search.solr.CustomDoSFilter",
              "df_graphite_servers": "[\"graphite-solrcloud.solr-graphite-cdc.graphite-solrcloud-monitor.ms-df-solrcloud.prod.walmart.com:2003\",\"graphite-solrcloud.solr-graphite-ndc.graphite-solrcloud-monitor.ms-df-solrcloud.prod.walmart.com:2003\"]",
              "release_urlbase": "http://nexus.prod.walmart.com/nexus/content/repositories/pangaea_releases/",
              "snapshot_urlbase": "http://gec-maven-nexus.walmart.com/nexus/content/repositories/pangaea_snapshots/",
              "solr_custom_comp_artifact": "com.walmart.strati.search.solr:solr-custom-components",
              "slow_query_logger": "log4j.logger.com.walmart.search.solr.SlowQueryLogger.QueryLog",
              "jetty_filter_url": "http://nexus.prod.walmart.com/nexus/content/repositories/pangaea_releases/com/walmart/strati/search/solr/solr-jetty-servlets/0.0.1/solr-jetty-servlets-0.0.1.jar",
              "config_url_v5": "http://nexus.prod.walmart.com/nexus/content/repositories/pangaea_releases/com/walmart/platform/forklift/solrpack/default-forklift-solr-5.5.1/1.0.1/default-forklift-solr-5.5.1-1.0.1.jar",
              "config_url_v6": "http://nexus.prod.walmart.com/nexus/content/repositories/pangaea_releases/com/walmart/platform/forklift/solrpack/default-forklift-solr-6.3.0/1.0.4/default-forklift-solr-6.3.0-1.0.4.jar",
              "config_url_v7": "http://gec-maven-nexus.walmart.com/content/repositories/pangaea_releases/com/walmart/platform/forklift/solrpack/default-forklift-solr-7.1.0/1.0.5/default-forklift-solr-7.1.0-1.0.5.jar"
            }'
        }
