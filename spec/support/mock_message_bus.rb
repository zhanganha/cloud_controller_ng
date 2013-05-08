class MockMessageBus
  attr_reader :config, :nats

  class << self
    def configure(config)
      @instance ||= new(config)
      self
    end

    def config
      @instance.config
      self
    end

    def subscribe(subject, opts = {}, &blk)
    end

    def publish(subject, message = nil)
    end
  end

  private
  attr_reader :config

  def initialize(config)
    @config = config
    @nats = config[:nats] || MockNATS
  end
end
