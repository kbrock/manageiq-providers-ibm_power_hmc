class ManageIQ::Providers::IbmPowerHmc::InfraManager::Host < ::Host
  def capture_metrics(counters, start_time = nil, end_time = nil)
    samples = collect_samples(start_time, end_time)
    process_samples(counters, samples)
  end

  def collect_samples(start_time, end_time)
    ext_management_system.with_provider_connection do |connection|
      connection.managed_system_metrics(
        :sys_uuid => ems_ref,
        :start_ts => start_time,
        :end_ts   => end_time
      )
    rescue IbmPowerHmc::Connection::HttpError => e
      $ibm_power_hmc_log.error("error getting performance samples for host #{ems_ref}: #{e}")
      raise unless e.message.eql?("403 Forbidden") # TO DO - Capture should be disabled at Host level if PCM is not enabled

      []
    end
  end

  def process_samples(counters, samples)
    metrics = {}
    samples.dig(0, "systemUtil", "utilSamples")&.each do |s|
      ts = Time.xmlschema(s["sampleInfo"]["timeStamp"])
      metrics[ts] = {}
      counters.each_key do |key|
        val = get_sample_value(s, key)
        metrics[ts][key] = val unless val.nil?
      end
    end
    metrics
  end

  private

  SAMPLE_DURATION = 30.0 # seconds

  def cpu_usage_rate_average(sample)
    100.0 * sample["utilizedProcUnits"].sum / sample["configurableProcUnits"].sum
  end

  def disk_usage_rate_average_vios(sample)
    usage = sample.values.sum do |adapters|
      adapters.select { |a| a.kind_of?(Hash) }.sum { |adapter| adapter["transmittedBytes"]&.sum || 0.0 }
    end
    usage / SAMPLE_DURATION / 1.0.kilobyte
  end

  def disk_usage_rate_average_all_vios(sample)
    sample["viosUtil"]&.sum { |vios| vios.key?("storage") ? disk_usage_rate_average_vios(vios["storage"]) : 0.0 }.to_f
  end

  def mem_usage_absolute_average(sample)
    a = sample["assignedMemToLpars"].sum
    c = sample["configurableMem"].sum
    c == 0.0 ? nil : 100.0 * a / c
  end

  def net_usage_rate_average_server(sample)
    usage = 0.0
    sample.values.each do |adapters|
      adapters.each do |adapter|
        adapter["physicalPorts"].each do |phys_port|
          usage += phys_port["transferredBytes"].sum
        end
      end
    end
    usage / SAMPLE_DURATION / 1.0.kilobyte
  end

  def net_usage_rate_average_vios(sample)
    usage = 0.0
    sample.values.each do |adapters|
      adapters.select { |a| a.kind_of?(Hash) }.each do |adapter|
        usage += adapter["transferredBytes"].sum
      end
    end
    usage / SAMPLE_DURATION / 1.0.kilobyte
  end

  def net_usage_rate_average_all_vios(sample)
    sample["viosUtil"].sum do |vios|
      if vios["network"]
        net_usage_rate_average_vios(vios["network"])
      else
        0.0
      end
    end
  end

  def get_sample_value(sample, key)
    case key
    when "cpu_usage_rate_average"
      s = sample.dig("serverUtil", "processor")
      unless s.nil?
        cpu_usage_rate_average(s)
      end
    when "disk_usage_rate_average"
      disk_usage_rate_average_all_vios(sample)
    when "mem_usage_absolute_average"
      s = sample.dig("serverUtil", "memory")
      unless s.nil?
        mem_usage_absolute_average(s)
      end
    when "net_usage_rate_average"
      s = sample.dig("serverUtil", "network")
      if s
        net_usage_rate_average_server(s) +
          net_usage_rate_average_all_vios(sample)
      end
    end
  end
end
