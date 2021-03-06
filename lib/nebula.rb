require 'erb'
require 'opennebula'
require 'yaml'
require 'ipaddress'

module Now
  EXPIRE_LENGTH = 8 * 60 * 60

  # NOW core class for communication with OpenNebula
  class Nebula
    attr_accessor :logger, :config
    @authz_ops = nil
    @authz_vlan = nil
    @ctx = nil
    @uid = nil
    @user = nil

    def one_connect(url, credentials)
      logger.debug "Connecting to #{url} ..."
      OpenNebula::Client.new(credentials, url)
    end

    # Connect to OpenNebula as given user
    #
    # There are two modes:
    #
    # 1) admin_user with server_cipher driver and user must be specified in query parameter
    #
    # 2) admin_user with regular password and user may not be specified
    #    Impersonation is not possible.
    #
    # In multi-user environment the choice 1) is needed.
    #
    # @param user [String] user name (nil for direct login as admin_user)
    def switch_user(user, admin_login)
      admin_user = config['opennebula']['admin_user']
      admin_password = config['opennebula']['admin_password']
      login = if admin_login
                admin_user
              else
                user
              end

      if user
        logger.info "Authentication from #{admin_user} to #{login}"

        server_auth = ServerCipherAuth.new(admin_user, admin_password)
        expiration = Time.now.to_i + EXPIRE_LENGTH
        user_token = server_auth.login_token(expiration, login)

        @ctx = one_connect(@url, user_token)
        @user = user
      else
        logger.info "Authentication to #{admin_user}"

        direct_token = "#{admin_user}:#{admin_password}"
        @ctx = one_connect(@url, direct_token)
        @user = admin_user
      end
    end

    def initialize(config)
      @logger = $logger
      logger.info "Starting Network Orchestrator Wrapper (NOW #{VERSION})"

      @config = config
      #logger.debug "[nebula] Configuration: #{config}"

      raise NowError.new(500), 'NOW not configured' if !config.key?('opennebula') || !config['opennebula'] || !config['opennebula'].key?('endpoint')
      @url = config['opennebula']['endpoint']
    end

    # Fetch data needed for authorization decisions and connect to OpenNebula
    # under specified user.
    #
    # @param user [String] user name (nil for direct login as admin_user)
    # @param operations [Set] planned operations: :create, :update, :delete, :get
    def init_authz(user, operations)
      @logger = $logger
      # only create and update operations need to fetch information about networks
      extended_authz = !(Set[:create, :update] & operations).empty?
      write_authz = !(Set[:create, :delete, :update] & operations).empty?

      # for create operation we need user id number
      # (scaning users on behalf of logged user is more cheap)
      @uid = nil
      unless (Set[:create] & operations).empty?
        switch_user(user, false)
        user_pool = OpenNebula::UserPool.new(@ctx)
        check(user_pool.info)
        logger.debug "[#{__method__}] #{user_pool.to_xml}" if config.key?('debug') && config['debug'] && config['debug'].key?('dumps') && config['debug']['dumps']
        user_pool.each do |u|
          if u['NAME'] == user
            @uid = u.id
            break
          end
        end
        logger.info "[#{__method__}] user ID: #{@uid}"
        raise NowError.new(400), "User #{user} not found" unless @uid
      end

      if extended_authz
        logger.debug "[#{__method__}] extended authorization needed, data will be fetched"

        switch_user(user, true)

        @authz_ops = Set[:get]
        @authz_vlan = {}
        list_networks.each do |n|
          # VLAN explicitly as string to reliable compare
          @authz_vlan[n.vlan.to_s] = n.user if n.vlan
        end
        logger.debug "[#{__method__}] scanned VLANs: #{@authz_vlan}"
      else
        logger.debug "[#{__method__}] extended authorization not needed for #{op2str operations}"
      end

      # write operations need to connect to OpenNebula with NOW admin service account
      if write_authz
        switch_user(user, true) unless extended_authz
      else
        switch_user(user, false)
      end

      @authz_ops = operations
    end

    # List all accessible OpenNebula networks
    def list_networks
      authz(Set[:get], nil, nil)
      vn_pool = OpenNebula::VirtualNetworkPool.new(@ctx, -1)
      check(vn_pool.info)

      networks = []
      vn_pool.each do |vn|
        begin
          network = parse_network(vn)
          networks << network
        rescue NowError => e
          logger.warn "[code #{e.code}] #{e.message}, skipping"
        end
      end

      networks
    end

    # Get information about OpenNebula network
    #
    # @param network_id [String] OpenNebula network ID
    def get(network_id)
      logger.debug "[#{__method__}] #{network_id}"
      authz(Set[:get], nil, nil)
      vn_generic = OpenNebula::VirtualNetwork.build_xml(network_id)
      vn = OpenNebula::VirtualNetwork.new(vn_generic, @ctx)
      check(vn.info)

      parse_network(vn)
    end

    # Create OpenNebula network
    #
    # @param netinfo [Now::Network] network to create
    def create_network(netinfo)
      authz(Set[:create], nil, netinfo)
      logger.debug "[#{__method__}] #{netinfo}"
      logger.info "[#{__method__}] network ID ignored (set by OpenNebula)" if netinfo.id
      logger.info "[#{__method__}] network owner ignored (will be '#{@user}')" if netinfo.user

      range = netinfo.range
      if range && range.address && range.address.ipv6?
        logger.warn "[#{__method__}] Network prefix 64 for IPv6 network required (#{range.address.to_string})" unless range.address.prefix == 64
      end
      default_cluster = if config.key?('opennebula') && config['opennebula'].key?('cluster')
                          config['opennebula']['cluster']
                        else
                          OpenNebula::ClusterPool::NONE_CLUSTER_ID
                        end
      cluster = if netinfo.zone
                  netinfo.zone
                else
                  default_cluster
                end
      vn_generic = OpenNebula::VirtualNetwork.build_xml
      vn = OpenNebula::VirtualNetwork.new(vn_generic, @ctx)

      template = raw2template_network(netinfo, {}, nil) + "\n" + raw2template_range(netinfo.range, {})
      logger.debug "[#{__method__}] template: #{template}"

      check(vn.allocate(template, cluster))
      id = vn.id.to_s
      logger.info "[#{__method__}] created network: #{id}"

      check(vn.chown(@uid, -1))
      logger.debug "[#{__method__}] ownership of network #{id} changed to #{@uid}"

      id
    end

    # Delete OpenNebula network
    #
    # @param network_id [String] OpenNebula network ID
    def delete_network(network_id)
      logger.debug "[#{__method__}] #{network_id}"
      vn_generic = OpenNebula::VirtualNetwork.build_xml(network_id)
      vn = OpenNebula::VirtualNetwork.new(vn_generic, @ctx)
      check(vn.info)
      authz(Set[:delete], vn, nil)
      check(vn.delete)
      logger.info "[#{__method__}] deleted network: #{network_id}"
    end

    # Update OpenNebula network
    #
    # Limitations from OpenNebula:
    #
    # 1) Only name and address range can be modified by regular users
    #
    # 2) Changing IP address type between IPv4/IPv6 doesn't work
    #
    # 3) All NOW-managed networks already has address range. If not, update will try to add it, but
    #    that requires additional ADMIN NET privilege.
    #
    # @param network_id [String] OpenNebula network ID
    # @param netinfo [Now::Network] sparse network structure with attributes to modify
    def update_network(network_id, netinfo)
      logger.debug "[#{__method__}] #{network_id}, #{netinfo}"
      #logger.debug "[#{__method__}] #{netinfo}"
      logger.info "[#{__method__}] Network ID ignored (got from URL)" if netinfo.id
      logger.info "[#{__method__}] Network owner ignored (change not implemented)" if netinfo.user

      vn_generic = OpenNebula::VirtualNetwork.build_xml(network_id)
      vn = OpenNebula::VirtualNetwork.new(vn_generic, @ctx)
      check(vn.info)
      authz(Set[:update], vn, netinfo)

      if netinfo.title
        logger.info "[#{__method__}] renaming network #{network_id} to '#{netinfo.title}'"
        check(vn.rename(netinfo.title))
      end

      range = netinfo.range
      if range
        ar_id = nil
        vn.each('AR_POOL/AR') do |ar|
          ar_id = ar['AR_ID']
          break
        end
        if ar_id
          template = raw2template_range(range, 'AR_ID' => ar_id)
          logger.debug "[#{__method__}] address range template: #{template}"
          logger.info "[#{__method__}] updating address range #{ar_id} in network #{network_id}"
          check(vn.update_ar(template))
        else
          # try to add address range if none found (should not happen with NOW-managed networks),
          # but that requires ADMIN NET privileges in OpenNebula
          template = raw2template_range(range, {})
          logger.debug "[#{__method__}] address range template: #{template}"
          logger.info "[#{__method__}] adding address range to network #{network_id}"
          check(vn.add_ar(template))
        end
      end

      # change also all non-OpenNebula attributes inside network template
      template = raw2template_network(netinfo, {}, vn)
      logger.debug "[#{__method__}] append template: #{template}"

      check(vn.update(template, true))
      id = vn.id.to_s
      logger.info "[#{__method__}] updated network: #{id}"

      id
    end

    private

    # Check authorization
    #
    # Raised error if not passed.
    #
    # Most of the authorization is up to OpenNebula. NOW component only check
    # if one user doesn't use other users' VLAN ID.
    #
    # @param operations [Set] operations to perform (:get, :create, :modify, :delete)
    # @param network [Now::Network] network (for :create and :modify)
    def authz(operations, network_old, network_new)
      if network_new && network_new.vlan
        logger.debug "[#{__method__}] checking VLAN #{network_new.vlan}, operations #{op2str operations}"
      else
        logger.debug "[#{__method__}] checking operations #{op2str operations}"
      end
      raise NowError.new(500), 'NOW authorization not initialized' unless @authz_ops

      missing = operations - @authz_ops
      raise NowError.new(500), "NOW authorization not enabled for operations #{op2str missing}" unless missing.empty?

      unless (Set[:delete, :update] & operations).empty?
        raise NowError.new(403), "#{@user} not authorized to perform #{op2str operations} on network #{network_old.id}" unless network_old['UNAME'] == @user
      end

      operations &= Set[:create, :update]
      return true if operations.empty? || !network_new.vlan

      # VLAN explicitly as string to reliable compare
      network_new.vlan = network_new.vlan.to_s
      if @authz_vlan.key?(network_new.vlan)
        owner = @authz_vlan[network_new.vlan]
        logger.debug "[#{__method__}] for VLAN #{network_new.vlan} found owner #{owner}"
        raise NowError.new(403), "#{@user} not authorized to use VLAN #{network_new.vlan} for operations #{op2str operations}" if owner != @user
      else
        logger.debug "[#{__method__}] VLAN #{network_new.vlan} is free"
      end
    end

    def op2str(operations)
      if operations
        operations.to_a.sort.join ', '
      else
        '(none)'
      end
    end

    def error_one2http(errno)
      case errno
      when OpenNebula::Error::ESUCCESS
        200
      when OpenNebula::Error::EAUTHENTICATION
        401
      when OpenNebula::Error::EAUTHORIZATION
        403
      when OpenNebula::Error::ENO_EXISTS
        404
      when OpenNebula::Error::EXML_RPC_API
        500
      when OpenNebula::Error::EACTION
        400
      when OpenNebula::Error::EINTERNAL
        500
      when OpenNebula::Error::ENOTDEFINED
        501
      else
        500
      end
    end

    def check(return_code)
      return true unless OpenNebula.is_error?(return_code)

      code = error_one2http(return_code.errno)
      raise NowError.new(code), return_code.message
    end

    def parse_range(vn_id, vn, ar)
      id = ar && ar['AR_ID'] || '(undef)'
      type = ar && ar['TYPE']
      ip = ar && ar['NETWORK_ADDRESS']
      ip = vn['TEMPLATE/NETWORK_ADDRESS'] if !ip || ip.empty?
      mask = ar && ar['NETWORK_MASK']
      mask = vn['TEMPLATE/NETWORK_MASK'] if !mask || mask.empty?

      case type
      when 'IP4'
        ip = ar['IP']
        if ip.nil? || ip.empty?
          raise NowError.new(422), "Missing 'IP' in the address range #{id} of network #{vn_id}"
        end
        address = IPAddress ip
        address.prefix = 24 unless ip.include? '/'

        gateway = ar && ar['GATEWAY']
        gateway = vn['TEMPLATE/GATEWAY'] if !gateway || gateway.empty?

      when 'IP6', 'IP4_6'
        ip = ar['GLOBAL_PREFIX']
        ip = ar['ULA_PREFIX'] if !ip || ip.empty?
        if ip.nil? || ip.empty?
          raise NowError.new(422), "Missing 'GLOBAL_PREFIX' in the address range #{id} of network #{vn_id}"
        end
        address = IPAddress ip
        address.prefix = 64 unless ip.include? '/'

        gateway = ar && ar['GATEWAY6']
        gateway = vn['TEMPLATE/GATEWAY6'] if !gateway || gateway.empty?

      when nil
        return nil if !ip || ip.empty?
        address = IPAddress ip

      else
        raise NowError.new(501), "Unknown type '#{type}' in the address range #{id} of network #{vn_id}"
      end

      # get the mask from NETWORK_MASK network parameter, if IP not in CIDR notation already
      unless ip.include? '/'
        if mask && !mask.empty?
          if /\d+\.\d+\.\d+\.\d+/ =~ mask
            address.netmask = mask
          else
            address.prefix = mask.to_i
          end
        end
      end

      if gateway
        gateway = IPAddress gateway if gateway
        logger.debug "[#{__method__}] network id=#{vn_id}, address=#{address.to_string}, gateway=#{gateway}"
      else
        logger.debug "[#{__method__}] network id=#{vn_id}, address=#{address.to_string}"
      end
      Now::Range.new(address: address, allocation: 'dynamic', gateway: gateway)
    end

    def parse_ranges(vn_id, vn)
      ar = nil
      vn.each('AR_POOL/AR') do |a|
        unless ar.nil?
          raise NowError.new(501), "Multiple address ranges found in network #{vn_id}"
        end
        ar = a
      end
      parse_range(vn_id, vn, ar)
    end

    def parse_cluster(vn_id, vn)
      cluster = nil
      vn.each('CLUSTERS/ID') do |cluster_xml|
        id = cluster_xml.text
        logger.debug "[#{__method__}] cluster: #{id}"
        unless cluster.nil?
          raise NowError.new(501), "Multiple clusters assigned to network #{vn_id}"
        end
        cluster = id
      end
      cluster
    end

    def parse_network(vn)
      logger.debug "[#{__method__}] #{vn.to_xml}" if config.key?('debug') && config['debug'] && config['debug'].key?('dumps') && config['debug']['dumps']

      id = vn.id
      title = vn.name
      desc = vn['DESCRIPTION'] || vn['TEMPLATE/DESCRIPTION']
      desc && desc.empty? && desc = nil
      vlan = vn['VLAN_ID'] || vn['TEMPLATE/VLAN_ID']
      vlan && vlan.empty? && vlan = nil

      range = parse_ranges(id, vn)
      zone = parse_cluster(id, vn)
      network = Network.new(
        id: id,
        title: title,
        description: desc,
        user: vn['UNAME'],
        vlan: vlan,
        range: range,
        zone: zone
      )
      logger.debug "[#{__method__}] #{network}"

      network
    end

    def raw2template_network(netinfo, attributes, old_vn)
      range = netinfo.range

      attributes.merge!(config['network']) if config.key?('network') && config['network']
      attributes['NAME'] = netinfo.title if netinfo.title
      attributes['DESCRIPTION'] = netinfo.description if netinfo.description
      if netinfo.vlan
        attributes['VLAN_ID'] = netinfo.vlan
        attributes.delete('AUTOMATIC_VLAN_ID') if attributes.key?('AUTOMATIC_VLAN_ID')
      end
      if range
        address = range.address
        attributes['GATEWAY'] = range.gateway if range.gateway && address.ipv4?
        attributes['GATEWAY6'] = range.gateway if range.gateway && address.ipv6?
        attributes['NETWORK_ADDRESS'] = address.network.to_s
        attributes['NETWORK_MASK'] = address.netmask if address.ipv4?
        attributes['NETWORK_MASK'] = address.prefix if address.ipv6?
      end

      if old_vn
        attributes.keys.each do |key|
          if old_vn.has_elements?(key)
            logger.debug "[#{__method__}] removing internal attribute #{key}"
            attributes.delete(key)
          end
        end
      end

      b = binding
      ERB.new(::File.new(::File.join(config['template_dir'], 'network.erb')).read, 0, '%').result b
    end

    def raw2template_range(range, rattributes)
      return '' unless range

      address = IPAddress(range.address.to_string)
      if address.ipv4?
        rattributes['TYPE'] = 'IP4'
        if address.prefix < 31
          address[3] += 1 if address == address.network
          rattributes['IP'] = address.to_s
          rattributes['SIZE'] = address.size - 2
        else
          rattributes['IP'] = address.to_s
          rattributes['SIZE'] = address.size
        end
      end
      if address.ipv6?
        rattributes['TYPE'] = 'IP6'
        # local IPv6 address doesn't work in OpenNebula 5.1.80 ==> always use global
        rattributes['GLOBAL_PREFIX'] = address.network.to_s
        #if IPAddress('fc00::/7').include? address
        #  rattributes['ULA_PREFIX'] = address.network.to_s
        #else
        #  rattributes['GLOBAL_PREFIX'] = address.network.to_s
        #end
        rattributes['SIZE'] = address.size >= 2**31 ? 2**31 : address.size - 2
      end

      b = binding
      ERB.new(::File.new(::File.join(config['template_dir'], 'range.erb')).read, 0, '%').result b
    end
  end
end
