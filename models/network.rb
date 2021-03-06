require 'date'

module Now
  # Network object
  class Network < NowObject
    # OpenNebula ID
    attr_accessor :id

    # Network title
    attr_accessor :title

    # Network summary
    attr_accessor :description

    # Owner
    attr_accessor :user

    # VLAN ID
    attr_accessor :vlan

    # IP address range (reader)
    attr_reader :range

    # IP address range (writer)
    def range=(new_value)
      unless valid_range?(new_value)
        raise NowError.new(500), 'Invalid range type'
      end
      @range = new_value
    end

    # Network state (active, inactive, error)
    attr_accessor :state

    # Availability zone (cluster)
    attr_accessor :zone

    def initialize(parameters = {})
      range = parameters.key?(:range) && parameters[:range] || parameters.key?('range') && parameters['range']
      if range && !valid_range?(range)
        raise NowError.new(500), 'Valid range object required in network object'
      end
      super
    end

    # Check to see if the all the properties in the model are valid
    # @return true if the model is valid
    def valid?
      valid_range?(range)
    end

    # Checks equality by comparing each attribute.
    # @param [Object] Object to be compared
    def ==(other)
      return true if equal?(other)
      self.class == other.class &&
        id == other.id &&
        title == other.title &&
        description == other.description &&
        user == other.user &&
        vlan == other.vlan &&
        range == other.range &&
        state == other.state &&
        zone == other.zone
    end

    # @see the `==` method
    # @param [Object] Object to be compared
    def eql?(other)
      self == other
    end

    # Calculates hash code according to all attributes.
    # @return [Fixnum] Hash code
    def hash
      [id, title, description, user, vlan, range, state, zone].hash
    end

    def merge!(other)
      @id = other.id if other.id
      @title = other.title if other.title
      @description = other.description if other.description
      @user = other.user if other.user
      @vlan = other.vlan if other.vlan
      @range = other.range if other.range
      @state = other.state if other.state
      @zone = other.zone if other.zone
    end

    # Returns the string representation of the object
    # @return [String] String presentation of the object
    def to_s
      to_hash.to_s
    end

    # Returns the object in the form of hash
    # @return [Hash] Returns the object in the form of hash
    def to_hash
      h = {}
      [:id, :title, :description, :user, :vlan, :range, :state, :zone].each do |k|
        v = instance_variable_get "@#{k}"
        v.nil? || h[k] = _to_hash(v)
      end

      h
    end

    private

    def valid_range?(value)
      value.nil? || value.is_a?(Now::Range)
    end
  end
end
