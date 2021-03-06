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

  # Auth token
  # should default to /var/run/secrets/kubernetes.io/serviceaccount, but didn't want to deal with that right now
  config :auth_token, :validate => :string

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
    @logger.debug("lookup_cache is: " + lookup_cache[path].to_s)

    if lookup_cache[path]
      @logger.debug("cache hit")
      metadata = lookup_cache[path]
    else
      @logger.info("cache miss")

      metadata = get_file_info(path)
      return unless metadata

      pod = metadata['pod']
      namespace = metadata['namespace']
      container = metadata['container']
      return unless pod and namespace and container

      @logger.info("pod: " + pod)
      @logger.info("container: " + container)

      if data = get_kubernetes(namespace, pod)
        begin
          metadata.merge!(data)
          set_log_formats(metadata)

          lookup_cache[path] = metadata
        rescue TypeError => e
          @logger.info("TypeError when caching metadata: #{data} #{e}")
        rescue => e
          @logger.info("Unexpected error when caching metadata: #{e}")
        end
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
      n = metadata['container']

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
      @logger.info("Error setting log format: #{e}")
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
    kubernetes['container'] = parts[2].gsub(/-[0-9a-z]*$/, '')
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

    begin
      begin
        if @auth_token.nil?
          response = RestClient::Request.execute(:url => url, :method => :get, :verify_ssl => false)
        else
          response = RestClient::Request.execute(:url => url, :method => :get, :verify_ssl => false, headers: {:Authorization => "Bearer #{@auth_token}"})
        end
        apiResponse = response.body
        @logger.info("successfully queried the kubernetes api")
      rescue RestClient::ResourceNotFound
        @logger.info("Kubernetes returned an error while querying the API")
        return nil
      end

      if response.code != 200
        @logger.info("Non 200 response code returned: #{response.code}")
        return nil
      else
        begin
          parsed = LogStash::Json.load(apiResponse)
          data = {}
          data['labels'] = sanatize_keys(parsed['metadata']['labels'])
          data['annotations'] = sanatize_keys(parsed['metadata']['annotations'])
          return data
        rescue => e
          @logger.info("Unkown error while trying to load json response: #{e}")
          return nil
        end
      end

    rescue => e
      @logger.info("Unknown error while getting Kubernetes metadata: #{e}")
      return nil
    end
    return nil
  end

end
