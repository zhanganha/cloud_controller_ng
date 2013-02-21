# Copyright (c) 2009-2012 VMware, Inc.

require "vcap/stager/client"

module VCAP::CloudController
  class DeaPool
    ADVERTISEMENT_EXPIRATION = 10

    attr_reader :config, :message_bus

    def initialize(config, message_bus)
      @config = config
      @message_bus = message_bus
      @deas = {}
    end

    def register_subscriptions
      message_bus.subscribe("dea.advertise") do |msg|
        process_advertise_message(msg)
      end
    end

    def process_advertise_message(msg)
      mutex.synchronize do
        @deas[msg[:id]] = {
          :advertisement => msg,
          :last_update => Time.now,
        }
      end
    end

    def find_dea(mem)
      mutex.synchronize do
        @deas.keys.shuffle.each do |id|
          dea = @deas[id]
          if dea_expired?(dea)
            @deas.delete(id)
          elsif dea_meets_needs?(dea, mem)
            return id
          end
        end
        nil
      end
    end

    private

    def dea_expired?(dea)
      (Time.now.to_i - dea[:last_update].to_i) > ADVERTISEMENT_EXPIRATION
    end

    def dea_meets_needs?(dea, mem)
      stats = dea[:advertisement]
      stats[:available_memory] >= mem
    end

    def mutex
      @mutex ||= Mutex.new
    end
  end
end
