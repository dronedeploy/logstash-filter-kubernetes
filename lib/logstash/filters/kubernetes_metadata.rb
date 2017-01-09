# encoding: utf-8
require "logstash/filters/base"
require "logstash/namespace"
require "lru_redux"
require "rest-client"
require "uri"
require "logstash/json"

class LogStash::Filters::KubernetesMetadata < LogStash::Filters::Base

  attr_accessor :lookup_cache

  config_name "kubernetes_metadata"

  # The source field name which contains full path to kubelet log file.
  config :source, :validate => :string, :default => "path"

  # The target field name to write event kubernetes metadata.
  config :target, :validate => :string, :default => "kubernetes"

  # Kubernetes API
  config :api, :validate => :string, :default => "http://127.0.0.1:8001"

  # default log format
  config :default_log_format, :validate => :string, :default => "default"

  public
  def register
    @logger.debug("Registering Kubernetes Filter plugin")
    self.lookup_cache ||= LruRedux::ThreadSafeCache.new(1000,  900)
    @logger.debug("Created cache...")
  end

  # this is optimized for the single container case. it caches based on filename to avoid the
  # filename munging on every event.

  public
  def filter(event)
    path = event[@source]
    return unless source

    @logger.debug("Log entry has source field, beginning processing for Kubernetes")

    config = {}

    @logger.debug("path is: " + path.to_s)
    @logger.debug("config is: " + config.to_s)
    @logger.debug("lookup_cache is: " + lookup_cache[path].to_s)

    if lookup_cache[path]
      @logger.debug("metadata cache hit")
      metadata = lookup_cache[path]
    else
      @logger.debug("metadata cache miss")
      kubernetes = get_file_info(path)

      return unless kubernetes

      pod = kubernetes['pod']
      namespace = kubernetes['namespace']
      name = kubernetes['container_name']

      return unless pod and namespace and name

      metadata = kubernetes

      if data = get_kubernetes(namespace, pod)
        metadata.merge!(data)
        set_log_formats(metadata)
        lookup_cache[path] = metadata
      end
    end

    event[@target] = metadata
    return filter_matched(event)
  end

  def set_log_formats(metadata)
    begin

      format = {
        'stderr' => @default_log_format,
        'stdout' => @default_log_format
      }
      a = metadata['annotations']
      n = metadata['container_name']

      # check for log-format-<stream>-<name>, log-format-<name>, log-format-<stream>, log-format
      # in annotations
      %w{ stderr stdout }.each do |t|
        [ "log-format-#{t}-#{n}", "log-format-#{n}", "log-format-#{t}", "log-format" ].each do |k|
          if v = a[k]
            format[t] = v
            break
          end
        end
      end

      metadata['log_format_stderr'] = format['stderr']
      metadata['log_format_stdout'] = format['stdout']
      @logger.debug("kubernetes metadata => #{metadata}")

    rescue => e
      @logger.warn("Error setting log format: #{e}")
    end
  end

  # based on https://github.com/vaijab/logstash-filter-kubernetes/blob/master/lib/logstash/filters/kubernetes.rb
  def get_file_info(path)
    parts = path.split(File::SEPARATOR).last.gsub(/.log$/, '').split('_')
    if parts.length != 3 || parts[2].start_with?('POD-')
      return nil
    end
    kubernetes = {}
    kubernetes['replication_controller'] = parts[0].gsub(/-[0-9a-z]*$/, '')
    kubernetes['pod'] = parts[0]
    kubernetes['namespace'] = parts[1]
    kubernetes['container_name'] = parts[2].gsub(/-[0-9a-z]*$/, '')
    kubernetes['container_id'] = parts[2].split('-').last
    return kubernetes
  end

  def sanatize_keys(data)
    return {} unless data

    parsed_data = {}
    data.each do |k,v|
      new_key = k.gsub(/\.|,/, '_')
        .gsub(/\//, '-')
      parsed_data[new_key] = v
    end

    return parsed_data
  end

  def get_kubernetes(namespace, pod)
    

    url = [ @api, 'api/v1/namespaces', namespace, 'pods', pod ].join("/")

    unless apiResponse = lookup_cache[url]
      begin
        begin
          response = RestClient::Request.execute(:url => url, :method => :get, :verify_ssl => false)
          apiResponse = response.body
          lookup_cache[url] = apiResponse
        rescue RestClient::ResourceNotFound
          @logger.debug("Kubernetes returned an error while querying the API")
          return nil
        end

        if response.code != 200
          @logger.warn("Non 200 response code returned: #{response.code}")
        end

        return nil unless response.code == 200

        data = LogStash::Json.load(apiResponse)

        {
          'annotations' => sanatize_keys(data['metadata']['annotations']),
          'labels' => sanatize_keys(data['metadata']['labels'])
        }

        begin
          data = LogStash::Json.load(apiResponse)
          {
            'annotations' => sanatize_keys(data['metadata']['annotations']),
            'labels' => sanatize_keys(data['metadata']['labels'])
          }
        rescue => e
          @logger.warn("Unkown error while trying to load json response")
        end
      rescue => e
        @logger.warn("Unknown error while getting Kubernetes metadata: #{e}")
      end
    end
  end

end
