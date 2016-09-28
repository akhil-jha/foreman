require 'test_helper'

class HostTest < ActiveSupport::TestCase
  setup do
    disable_orchestration
    User.current = users :admin
    Setting[:token_duration] = 0
    Foreman::Model::EC2.any_instance.stubs(:image_exists?).returns(true)
  end

  test "should not save hostname with periods in shortname" do
    host = Host.new :name => "my.host", :domain => Domain.where(:name => "mydomain.net").first_or_create, :managed => true
    host.valid?
    assert_equal "must not include periods", host.errors[:name].first
  end

  test "existing interface can be assigned as host primary interface" do
    host = FactoryGirl.build(:host, :managed)
    host.interfaces = [] # remove existing primary interface
    host.interfaces = [ FactoryGirl.create(:nic_managed, :primary => true, :host => host,
                                           :domain => FactoryGirl.create(:domain)) ]
    assert host.save
  end

  test "should fix mac address hyphens" do
    host = Host.create :name => "myhost", :mac => "aa-bb-cc-dd-ee-ff"
    assert_equal "aa:bb:cc:dd:ee:ff", host.mac
  end

  test "should fix mac address" do
    host = Host.create :name => "myhost", :mac => "aabbccddeeff"
    assert_equal "aa:bb:cc:dd:ee:ff", host.mac
  end

  test "should keep valid mac address" do
    host = Host.create :name => "myhost", :mac => "aa:bb:cc:dd:ee:ff"
    assert_equal "aa:bb:cc:dd:ee:ff", host.mac
  end

  test "should fix 64-bit mac address hyphens" do
    host = Host.create :name => "myhost", :mac => "aa-bb-cc-dd-ee-ff-00-11-22-33-44-55-66-77-88-99-aa-bb-cc-dd"
    assert_equal "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd", host.mac
  end

  test "should fix 64-bit mac address" do
    host = Host.create :name => "myhost", :mac => "aabbccddeeff00112233445566778899aabbccdd"
    assert_equal "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd", host.mac
  end

  test "should keep valid 64-bit mac address" do
    host = Host.create :name => "myhost", :mac => "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd"
    assert_equal "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd", host.mac
  end

  test "should be valid using 64-bit mac address" do
    host = FactoryGirl.create(:host)
    host.mac = "aa:bb:cc:dd:ee:ff:00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd"
    host.save!
    assert_equal true, host.valid?
  end

  test "should fix ip address if a leading zero is used" do
    host = Host.create :name => "myhost", :mac => "aabbccddeeff", :ip => "123.01.02.03"
    assert_equal "123.1.2.3", host.ip
  end

  test "should add domain name to hostname" do
    host = Host.create :name => "myhost", :mac => "aabbccddeeff", :ip => "123.01.02.03",
      :domain => Domain.where(:name => "company.com").first_or_create
    assert_equal "myhost.company.com", host.name
  end

  test "should not add domain name to hostname if it already include it" do
    host = Host.create :name => "myhost.company.com", :mac => "aabbccddeeff", :ip => "123.1.2.3",
      :domain => Domain.where(:name => "company.com").first_or_create
    assert_equal "myhost.company.com", host.name
  end

  test "should add hostname if it contains domain name" do
    host = Host.create :name => "myhost.company.com", :mac => "aabbccddeeff", :ip => "123.01.02.03",
      :domain => Domain.where(:name => "company.com").first_or_create
    assert_equal "myhost.company.com", host.name
  end

  test "should not append domainname to fqdn for unmanaged host" do
    host = Host.create :name => "myhost.sub.comp.net", :mac => "aabbccddeeff", :ip => "123.01.02.03",
      :domain => Domain.where(:name => "company.com").first_or_create,
      :certname => "myhost.sub.comp.net",
      :managed => false
    assert_equal "myhost.sub.comp.net", host.name
  end

  test "should save hosts with full stop in their name" do
    host = Host.create :name => "my.host.company.com", :mac => "aabbccddeeff", :ip => "123.01.02.03",
      :domain => Domain.where(:name => "company.com").first_or_create
    assert_equal "my.host.company.com", host.name
  end

  test "sets compute attributes on create" do
    Host.any_instance.expects(:set_compute_attributes).once.returns(true)
    Host.create! :name => "myfullhost", :mac => "aabbecddeeff", :ip => "2.3.4.3",
      :domain => domains(:mydomain), :operatingsystem => operatingsystems(:redhat), :medium => media(:one),
      :subnet => subnets(:two), :architecture => architectures(:x86_64), :puppet_proxy => smart_proxies(:puppetmaster),
      :environment => environments(:production), :disk => "empty partition"
  end

  test "should save compute attributes with indifferent access" do
    h = Host.new :name => "myfullhost", :mac => "aabbecddeeff", :ip => "2.3.4.3", :compute_attributes => {'attr1' => 'blah'}
    assert_equal 'blah', h.compute_attributes['attr1']
    assert_equal 'blah', h.compute_attributes[:attr1]
  end

  test "doesn't set compute attributes on update" do
    host = FactoryGirl.create(:host)
    Host.any_instance.expects(:set_compute_attributes).never
    host.update_attributes!(:mac => "52:54:00:dd:ee:ff")
  end

  test "can fetch vm compute attributes" do
    host = FactoryGirl.create(:host, :compute_resource => compute_resources(:ec2))
    ComputeResource.any_instance.stubs(:vm_compute_attributes_for).returns({:cpus => 4})
    assert_equal host.vm_compute_attributes, :cpus => 4
  end

  test "fetches nil vm compute attributes for bare metal" do
    host = FactoryGirl.create(:host)
    assert_equal host.vm_compute_attributes, nil
  end

  test "can authorize Host::Managed as non-admin user" do
    h = FactoryGirl.create(:host, :managed)
    setup_user('view', 'hosts', 'name ~ *')

    assert_includes Host.authorized('view_hosts'), h
  end

  context "when unattended is false" do
    def setup
      SETTINGS[:unattended] = false
    end

    def teardown
      SETTINGS[:unattended] = true
    end

    test "should be able to save hosts with full domain" do
      host = Host.create :name => "myhost.foo", :mac => "aabbccddeeff", :ip => "123.01.02.03"
      assert_equal "myhost.foo", host.fqdn
    end

    test "should be able to save hosts with no domain" do
      host = Host.create :name => "myhost", :mac => "aabbccddeeff", :ip => "123.01.02.03"
      assert_equal "myhost", host.fqdn
    end
  end

  test "should be able to save host" do
    host = Host.create :name => "myfullhost", :mac => "aabbecddeeff", :ip => "2.3.4.3",
      :domain => domains(:mydomain), :operatingsystem => operatingsystems(:redhat), :medium => media(:one),
      :subnet => subnets(:two), :architecture => architectures(:x86_64), :puppet_proxy => smart_proxies(:puppetmaster),
      :environment => environments(:production), :disk => "empty partition"
    assert host.valid?
    assert !host.new_record?
  end

  test "non-admin user should be able to create host with new lookup value" do
    User.current = users(:one)
    User.current.roles << [roles(:manager)]
    assert_difference('LookupValue.count') do
      assert Host.create! :name => "abc.mydomain.net", :mac => "aabbecddeeff", :ip => "2.3.4.3",
      :domain => domains(:mydomain), :operatingsystem => operatingsystems(:redhat),
      :subnet => subnets(:two), :architecture => architectures(:x86_64), :puppet_proxy => smart_proxies(:puppetmaster), :medium => media(:one),
      :environment => environments(:production), :disk => "empty partition",
      :lookup_values_attributes => {"new_123456" => {"lookup_key_id" => lookup_keys(:complex).id, "value"=>"some_value", "match" => "fqdn=abc.mydomain.net"}}
    end
  end

  test "lookup value has right matcher for a host" do
    assert_difference('LookupValue.where(:lookup_key_id => lookup_keys(:five).id, :match => "fqdn=abc.mydomain.net").count') do
      Host.create! :name => "abc", :mac => "aabbecddeeff", :ip => "2.3.4.3",
        :domain => domains(:mydomain), :operatingsystem => operatingsystems(:redhat), :medium => media(:one),
        :subnet => subnets(:two), :architecture => architectures(:x86_64), :puppet_proxy => smart_proxies(:puppetmaster),
        :environment => environments(:production), :disk => "empty partition",
        :lookup_values_attributes => {"new_123456" => {"lookup_key_id" => lookup_keys(:five).id, "value"=>"some_value"}}
    end
  end

  test "should be able to add new lookup value on update_attributes" do
    host = FactoryGirl.create(:host)
    lookup_key = lookup_keys(:three)
    assert_difference('LookupValue.count') do
      assert host.update_attributes!(:lookup_values_attributes => {:new_123456 =>
                                                                   {:lookup_key_id => lookup_key.id, :value => true, :match => "fqdn=#{host.fqdn}",
                                                                    :_destroy => 'false'}})
    end
  end

  test "should be able to delete existing lookup value on update_attributes" do
    host = FactoryGirl.create(:host)
    lookup_key = FactoryGirl.create(:puppetclass_lookup_key)
    lookup_value = FactoryGirl.create(:lookup_value, :lookup_key_id => lookup_key.id,
                                      :match => "fqdn=#{host.fqdn}", :value => '8080')
    host.reload
    assert_difference('LookupValue.count', -1) do
      assert host.update_attributes!(:lookup_values_attributes => {'0' =>
                                                                   {:lookup_key_id => lookup_key.id, :value => '8080', :match => "fqdn=#{host.fqdn}",
                                                                    :id => lookup_value.id, :_destroy => 'true'}})
    end
  end

  test "should be able to update lookup value on update_attributes" do
    host = FactoryGirl.create(:host)
    lookup_key = FactoryGirl.create(:puppetclass_lookup_key)
    lookup_value = FactoryGirl.create(:lookup_value, :lookup_key_id => lookup_key.id,
                                      :match => "fqdn=#{host.fqdn}", :value => '8080')
    host.reload
    assert_difference('LookupValue.count', 0) do
      assert host.update_attributes!(:lookup_values_attributes => {'0' =>
                                                                   {:lookup_key_id => lookup_key.id, :value => '80', :match => "fqdn=#{host.fqdn}",
                                                                    :id => lookup_value.id, :_destroy => 'false'}})
    end
    lookup_value.reload
    assert_equal '80', lookup_value.value
  end

  test "should be able to update complex YAML lookup value" do
    host = FactoryGirl.create(:host)
    lookup_key = FactoryGirl.create(:puppetclass_lookup_key, :key_type => 'yaml')
    lookup_value = FactoryGirl.create(:lookup_value, :lookup_key_id => lookup_key.id,
                                      :match => host.lookup_value_matcher, :value => YAML.dump(:foo => :bar))
    host.reload
    assert_difference('LookupValue.count', 0) do
      assert host.update_attributes!(:lookup_values_attributes => {'0' =>
                                                                   {:lookup_key_id => lookup_key.id.to_s, :value => YAML.dump(:updated => :value),
                                                                    :match => host.lookup_value_matcher,
                                                                    :id => lookup_value.id.to_s, :_destroy => 'false'}})
    end
    lookup_value.reload
    assert_equal({:updated => :value}, lookup_value.value)
  end

  test "should raise nested lookup value validation errors" do
    lookup_key = FactoryGirl.create(:puppetclass_lookup_key, :key_type => 'hash')
    host = FactoryGirl.build(:host)
    host.attributes = {:lookup_values_attributes => {'0' =>
                                                     {:lookup_key_id => lookup_key.id.to_s, :value => '{"a":',
                                                      :match => host.lookup_value_matcher,
                                                      :_destroy => 'false'}}}
    assert host.lookup_values.first.present?
    refute_valid host, :'lookup_values.value', /invalid hash/
  end

  test "should not trigger dhcp orchestration when importing facts" do
    host = Host.new(:name => "sinn1636.lan")
    host.stubs(:skip_orchestration?).returns(false)
    host.primary_interface.expects(:dhcp_conflict_detected?).never
    assert host.import_facts(read_json_fixture('facts/facts.json')['facts'])
  end

  test "should populate primary interface attributes even without existing interface" do
    host = FactoryGirl.create(:host, :managed => false)
    host.interfaces = []
    host.populate_fields_from_facts(:domain => 'example.com',
                                    :operatingsystem => 'RedHat',
                                    :operatingsystemrelease => '6.2',
                                    :macaddress_eth0 => '00:00:11:22:11:22',
                                    :ipaddress_eth0 => '192.168.0.1',
                                    :ipaddress6_eth0 => '2001:db8::1',
                                    :interfaces => 'eth0')
    assert_equal 'example.com', host.domain.name
    assert_equal '2001:db8::1', host.primary_interface.ip6
    refute host.primary_interface.managed?
  end

  test "#configuration? returns true when host has puppetmaster" do
    host = FactoryGirl.build(:host)
    refute host.configuration?

    proxy = FactoryGirl.create(:smart_proxy)
    host.puppet_proxy = proxy
    assert host.configuration?
  end

  context 'import host and facts' do
    test 'import_host does not require any' do
      host = Host.import_host('host', 'custom_type')
      assert_equal 'host', host.name
    end

    test 'import_host does downcase the name' do
      host = Host.import_host('HOST', 'custom_type')
      assert_equal 'host', host.name
    end

    test 'import_facts only needs operatingsystem and lsbdistrelease fact' do
      host = Host.import_host('host', 'puppet')
      assert host.import_facts(:lsbdistrelease => '6.7', :operatingsystem => 'CentOS')
    end

    test 'should import facts from json of a new host when certname is not specified' do
      refute Host.find_by_name('sinn1636.lan')
      raw = read_json_fixture('facts/facts.json')
      host = Host.import_host(raw['name'], 'puppet')
      assert host.import_facts(raw['facts'])
      assert Host.find_by_name('sinn1636.lan')
    end

    test 'should import facts even when domain is not part of facts' do
      refute Host.find_by_name('sinn1636.lan')
      raw = read_json_fixture('facts/facts.json')
      raw.delete('domain')
      host = Host.import_host(raw['name'], 'puppet')
      assert host.import_facts(raw['facts'])
      assert Host.find_by_name('sinn1636.lan')
    end

    test 'should downcase hostname parameter from json of a new host' do
      raw = read_json_fixture('facts/facts_with_caps.json')
      host = Host.import_host(raw['name'], 'puppet')
      assert host.import_facts(raw['facts'])
      assert Host.find_by_name('sinn1636.lan')
    end

    test 'should downcase domain parameter from json of a new host' do
      raw = read_json_fixture('facts/facts_with_caps.json')
      host = Host.import_host(raw['name'], 'puppet')
      assert host.import_facts(raw['facts'])
      assert_equal raw['facts']['domain'].downcase, Host.find_by_name('sinn1636.lan').facts_hash['domain']
    end

    test 'should import facts idempotently' do
      raw = read_json_fixture('facts/facts_with_caps.json')
      host = Host.import_host(raw['name'], 'puppet')
      assert host.import_facts(raw['facts'])
      value_ids = Host.find_by_name('sinn1636.lan').fact_values.map(&:id)
      assert host.import_facts(raw['facts'])
      assert_equal value_ids.sort, Host.find_by_name('sinn1636.lan').fact_values.map(&:id).sort
    end

    test 'should find a host by certname not fqdn when provided' do
      Host.new(:name => 'sinn1636.fail', :certname => 'sinn1636.lan.cert', :mac => 'e4:1f:13:cc:36:58').save(:validate => false)
      assert Host.find_by_name('sinn1636.fail').ip.nil?
      # hostname in the json is sinn1636.lan, so if the facts have been updated for
      # this host, it's a successful identification by certname
      raw = read_json_fixture('facts/facts_with_certname.json')
      host = Host.import_host(raw['name'], 'puppet', raw['certname'])
      assert host.import_facts(raw['facts'])
      host = Host.find_by_name('sinn1636.fail')
      assert_equal '10.35.27.2', host.interfaces.find_by_identifier('br180').ip
      assert_equal nil, host.primary_interface.ip # eth0 does not have ip address among facts
    end

    test 'should update certname when host is found by hostname and certname is provided' do
      Host.new(:name => 'sinn1636.lan', :certname => 'sinn1636.cert.fail').save(:validate => false)
      assert_equal 'sinn1636.cert.fail', Host.find_by_name('sinn1636.lan').certname
      raw = read_json_fixture('facts/facts_with_certname.json')
      host = Host.import_host(raw['name'], 'puppet', raw['certname'])
      assert host.import_facts(raw['facts'])
      assert_equal 'sinn1636.lan.cert', Host.find_by_name('sinn1636.lan').certname
    end

    test 'host is created when uploading facts if setting is true' do
      assert_difference 'Host.count' do
        Setting[:create_new_host_when_facts_are_uploaded] = true
        raw = read_json_fixture('facts/facts_with_certname.json')
        host = Host.import_host(raw['name'], 'puppet', raw['certname'])
        assert host.import_facts(raw['facts'])
        assert Host.find_by_name('sinn1636.lan')
        Setting[:create_new_host_when_facts_are_uploaded] =
          Setting.find_by_name('create_new_host_when_facts_are_uploaded').default
      end
    end

    test 'host is not created when uploading facts if setting is false' do
      Setting[:create_new_host_when_facts_are_uploaded] = false
      refute Setting[:create_new_host_when_facts_are_uploaded]
      raw = read_json_fixture('facts/facts_with_certname.json')
      host = Host.import_host(raw['name'], 'puppet', raw['certname'])
      refute host.import_facts(raw['facts'])
      host = Host.find_by_name('sinn1636.lan')
      Setting[:create_new_host_when_facts_are_uploaded] =
        Setting.find_by_name('create_new_host_when_facts_are_uploaded').default
      assert_nil host
    end

    test 'host taxonomies are set to a default when uploading facts' do
      Setting[:create_new_host_when_facts_are_uploaded] = true
      raw = read_json_fixture('facts/facts.json')
      host = Host.import_host(raw['name'], 'puppet')
      assert host.import_facts(raw['facts'])

      assert_equal Setting[:default_location],     Host.find_by_name('sinn1636.lan').location.title
      assert_equal Setting[:default_organization], Host.find_by_name('sinn1636.lan').organization.title
    end

    test 'host taxonomies are set to setting[taxonomy_fact] if it exists' do
      Setting[:create_new_host_when_facts_are_uploaded] = true
      Setting[:location_fact] = "foreman_location"
      Setting[:organization_fact] = "foreman_organization"

      raw = read_json_fixture('facts/facts.json')
      raw['facts']['foreman_location']     = 'Location 2'
      raw['facts']['foreman_organization'] = 'Organization 2'
      host = Host.import_host(raw['name'], 'puppet')
      assert host.import_facts(raw['facts'])

      assert_equal 'Location 2',     Host.find_by_name('sinn1636.lan').location.title
      assert_equal 'Organization 2', Host.find_by_name('sinn1636.lan').organization.title
    end

    test 'default taxonomies are not assigned to hosts with taxonomies' do
      Setting[:default_location] = taxonomies(:location1).title
      raw = read_json_fixture('facts/facts.json')
      host = Host.import_host(raw['name'], 'puppet')
      assert host.import_facts(raw['facts'])
      Host.find_by_name('sinn1636.lan').update_attribute(:location, taxonomies(:location2))
      Host.find_by_name('sinn1636.lan').import_facts(raw['facts'])

      assert_equal taxonomies(:location2), Host.find_by_name('sinn1636.lan').location
    end

    test 'taxonomies from facts override already existing taxonomies in hosts' do
      Setting[:create_new_host_when_facts_are_uploaded] = true
      Setting[:location_fact] = "foreman_location"
      Setting[:organization_fact] = "foreman_organization"

      raw = read_json_fixture('facts/facts.json')
      raw['facts']['foreman_location'] = 'Location 2'
      host = Host.import_host(raw['name'], 'puppet')
      assert host.import_facts(raw['facts'])

      Host.find_by_name('sinn1636.lan').update_attribute(:location, taxonomies(:location1))
      Host.find_by_name('sinn1636.lan').import_facts(raw['facts'])

      assert_equal taxonomies(:location2), Host.find_by_name('sinn1636.lan').location
    end
  end

  test "host is created when receiving a report if setting is true" do
    assert_difference 'Host.count' do
      Setting[:create_new_host_when_report_is_uploaded] = true
      ConfigReport.import read_json_fixture("reports/no-logs.json")
      assert Host.find_by_name('builder.fm.example.net')
      Setting[:create_new_host_when_report_is_uploaded] =
        Setting.find_by_name("create_new_host_when_facts_are_uploaded").default
    end
  end

  test "host is not created when receiving a report if setting is false" do
    Setting[:create_new_host_when_report_is_uploaded] = false
    assert_equal false, Setting[:create_new_host_when_report_is_uploaded]
    ConfigReport.import read_json_fixture("reports/no-logs.json")
    host = Host.find_by_name('builder.fm.example.net')
    Setting[:create_new_host_when_report_is_uploaded] =
      Setting.find_by_name("create_new_host_when_facts_are_uploaded").default
    assert_nil host
  end

  test 'host #refresh_global_status defaults to OK' do
    host = FactoryGirl.build(:host)
    assert_empty host.host_statuses
    host.refresh_global_status
    assert_equal HostStatus::Global::OK, host.global_status
  end

  test 'host #get_status(type) builds a new status if there is none yet and returns existing one otherwise' do
    host = FactoryGirl.build(:host)
    status = host.get_status(HostStatus::BuildStatus)
    assert status.new_record?
    assert_equal host, status.host

    status.refresh!
    new_status = host.get_status(HostStatus::BuildStatus)
    assert_equal status, new_status
  end

  test 'host #get_status(type) only builds a new status once' do
    host = FactoryGirl.build(:host)
    status1 = host.get_status(HostStatus::BuildStatus)
    assert status1.new_record?
    status2 = host.get_status(HostStatus::BuildStatus)
    assert_equal status1.object_id, status2.object_id
  end

  test 'host #refresh_statuses saves all relevant statuses and refreshes global status' do
    ProxyAPI::Features.any_instance.stubs(:features => Feature.name_map.keys)
    host = FactoryGirl.create(:host, :with_puppet, :with_reports)
    host.reload
    host.global_status = 1

    host.refresh_statuses
    assert_equal 0, host.global_status
    refute_empty host.host_statuses
    assert host.get_status(HostStatus::BuildStatus).new_record? # BuildStatus was not #relevant? for unmanaged host
    refute host.get_status(HostStatus::ConfigurationStatus).new_record?
  end

  test 'host #refresh_global_status! updates global status in database' do
    host = FactoryGirl.build(:host)
    config_status = host.get_status(HostStatus::ConfigurationStatus)
    config_status.status = 1
    config_status.save!
    config_status.stubs(:relevant?).returns(true)
    HostStatus::ConfigurationStatus.any_instance.stubs(:error?).returns(true)

    assert_equal 0, host.global_status
    host.refresh_global_status!
    assert_equal 2, host.reload.global_status
  end

  test 'host #refresh_statuses updates global status in database' do
    host = FactoryGirl.build(:host)
    host.update_attribute(:global_status, 1)

    assert_equal 1, host.global_status
    host.refresh_statuses
    assert_equal 0, host.reload.global_status
  end

  test 'build status is updated on host validation' do
    host = FactoryGirl.build(:host)
    host.build = false
    host.valid?
    original_status = host.get_status(HostStatus::BuildStatus).to_status

    host.build = true
    host.valid?
    new_status = host.get_status(HostStatus::BuildStatus).to_status

    refute_equal original_status, new_status
  end

  test "assign a host to a location" do
    host = Host.create :name => "host 1", :mac => "aabbecddeeff", :ip => "5.5.5.5", :hostgroup => hostgroups(:common), :managed => false
    location = Location.create :name => "New York"

    host.location_id = location.id
    assert host.save!
  end

  test "update a host's location" do
    host = Host.create :name => "host 1", :mac => "aabbccddeeff", :ip => "5.5.5.5", :hostgroup => hostgroups(:common), :managed => false
    original_location = Location.create :name => "New York"

    host.location_id = original_location.id
    assert host.save!
    assert host.location_id = original_location.id

    new_location = Location.create :name => "Los Angeles"
    host.location_id = new_location.id
    assert host.save!
    assert host.location_id = new_location.id
  end

  test "assign a host to an organization" do
    host = Host.create :name => "host 1", :mac => "aabbecddeeff", :ip => "5.5.5.5", :hostgroup => hostgroups(:common), :managed => false
    organization = Organization.create :name => "Hosting client 1"

    host.organization_id = organization.id
    assert host.save!
  end

  test "assign a host to both a location and an organization" do
    host = Host.create :name => "host 1", :mac => "aabbccddeeff", :ip => "5.5.5.5", :hostgroup => hostgroups(:common), :managed => false
    location = Location.create :name => "Tel Aviv"
    organization = Organization.create :name => "Hosting client 1"

    host.location_id = location.id
    host.organization_id = organization.id

    assert host.save!
  end

  test 'host can be searched in multiple taxonomies' do
    org1 = FactoryGirl.create(:organization)
    org2 = FactoryGirl.create(:organization)
    org3 = FactoryGirl.create(:organization)
    user = FactoryGirl.create(:user, :organizations => [org1, org2])
    host1 = FactoryGirl.create(:host, :organization => org1)
    host2 = FactoryGirl.create(:host, :organization => org2)
    host3 = FactoryGirl.create(:host, :organization => org3)
    hosts = nil

    assert_nil Organization.current
    as_user(user) do
      hosts = Host::Managed.all
    end
    assert_includes hosts, host1
    assert_includes hosts, host2
    refute_includes hosts, host3

    as_user(:one) do
      hosts = Host::Managed.all
    end
    assert_includes hosts, host1
    assert_includes hosts, host2
    assert_includes hosts, host3
  end

  context "location or organizations are not enabled" do
    before do
      @original_loc, SETTINGS[:locations_enabled] = SETTINGS[:locations_enabled], false
      @original_org, SETTINGS[:organizations_enabled] = SETTINGS[:organizations_enabled], false
    end

    after do
      SETTINGS[:locations_enabled] = @original_loc
      SETTINGS[:organizations_enabled] = @original_org
    end

    test "should save if root password is undefined when the host is managed and in build mode" do
      Setting[:root_pass] = ''
      host = Host.new :name => "myfullhost", :managed => true, :build => false
      host.valid?
      refute host.errors[:root_pass].present?
    end

    test "should save if root password is undefined when the compute resource is image capable and in build mode" do
      host = Host.new :name => "myfullhost", :managed => true, :build => true, :compute_resource_id => compute_resources(:openstack).id
      host.valid?
      refute host.errors[:root_pass].any?
    end

    test "should not save if root password is undefined when the host is managed and in build mode" do
      Setting[:root_pass] = ''
      host = Host.new :name => "myfullhost", :managed => true, :build => true
      refute host.valid?
      assert host.errors[:root_pass].present?
    end

    test "should not save if neither ptable or disk are defined when the host is managed" do
      if unattended?
        host = Host.create :name => "myfullhost", :mac => "aabbecddeeff", :ip => "2.4.4.03",
          :domain => domains(:mydomain), :operatingsystem => Operatingsystem.first, :subnet => subnets(:two), :medium => media(:one),
          :architecture => Architecture.first, :environment => Environment.first, :managed => true
        refute_valid host
      end
    end

    test "should save if neither ptable or disk are defined when the host is not managed" do
      host = Host.create :name => "myfullhost", :mac => "aabbecddeeff", :ip => "2.3.4.03", :medium => media(:one),
        :domain => domains(:mydomain), :operatingsystem => operatingsystems(:redhat), :subnet => subnets(:two), :puppet_proxy => smart_proxies(:puppetmaster),
        :architecture => architectures(:x86_64), :environment => environments(:production), :managed => false
      assert host.valid?
    end

    test "should save if ptable is defined" do
      host = Host.create :name => "myfullhost", :mac => "aabbecddeeff", :ip => "2.3.4.03",
        :domain => domains(:mydomain), :operatingsystem => operatingsystems(:redhat), :puppet_proxy => smart_proxies(:puppetmaster), :medium => media(:one),
        :subnet => subnets(:two), :architecture => architectures(:x86_64), :environment => environments(:production), :ptable => Ptable.first
      assert !host.new_record?
    end

    test "should save if disk is defined" do
      host = Host.create :name => "myfullhost", :mac => "aabbecddeeff", :ip => "2.3.4.03",
        :domain => domains(:mydomain), :operatingsystem => operatingsystems(:redhat), :subnet => subnets(:two), :medium => media(:one),
        :architecture => architectures(:x86_64), :environment => environments(:production), :disk => "aaa", :puppet_proxy => smart_proxies(:puppetmaster)
      assert !host.new_record?
    end

    test "should not save if IP is not in the right subnet" do
      if unattended?
        host = Host.create :name => "myfullhost", :mac => "aabbecddeeff", :ip => "123.5.2.3", :ptable => FactoryGirl.create(:ptable),
          :domain => domains(:mydomain), :operatingsystem => Operatingsystem.first, :subnet => subnets(:two), :managed => true, :medium => media(:one),
          :architecture => Architecture.first, :environment => Environment.first, :puppet_proxy => smart_proxies(:puppetmaster),
          :ip6 => "2001:db8::1", :subnet6 => subnets(:six)
        refute host.valid?, "Host should be invalid: #{host.errors.messages}"
        assert_includes host.errors.messages.keys, :"interfaces.ip"
        assert_includes host.errors.messages.keys, :"interfaces.ip6"
      end
    end

    context 'owner_type validations' do
      test "should save if owner_type is User or Usergroup" do
        host = FactoryGirl.build(:host, :owner_type => "User", :owner => User.current)
        assert_valid host
      end

      test "should not save if owner_type is not User or Usergroup" do
        host = FactoryGirl.build(:host, :owner_type => "UserGr(up") # should be Usergroup
        refute_valid host
      end

      test 'should succeed validation if owner not set' do
        host = FactoryGirl.build(:host, :without_owner)
        assert_valid host
      end

      test "should not save if owner_type is set without owner" do
        host = FactoryGirl.build(:host, :owner_type => "Usergroup")
        refute_valid host
        assert_match(/owner must be specified/, host.errors[:owner].first)
      end

      test "should not save if owner_type is not in sync with owner" do
        host = FactoryGirl.build(:host, :owner => User.current)
        host.owner_type = 'Usergroup'
        refute_valid host
        assert_match(/Usergroup/, host.errors[:owner].first)
      end
    end

    test "should not save if owner_type is not User or Usergroup" do
      host = Host.new :name => "myfullhost", :mac => "aabbecddeeff", :ip => "3.3.4.03", :medium => media(:one),
        :domain => domains(:mydomain), :operatingsystem => operatingsystems(:redhat), :subnet => subnets(:two), :puppet_proxy => smart_proxies(:puppetmaster),
        :architecture => architectures(:x86_64), :environment => environments(:production), :managed => true,
        :owner_type => "UserGr(up" # should be Usergroup
      refute host.valid?
    end

    test "should not save if installation media is missing" do
      host = Host.new :name => "myfullhost", :mac => "aabbecddeeff", :ip => "3.3.4.03", :ptable => FactoryGirl.create(:ptable),
        :domain => domains(:mydomain), :operatingsystem => operatingsystems(:redhat), :subnet => subnets(:two), :puppet_proxy => smart_proxies(:puppetmaster),
        :architecture => architectures(:x86_64), :environment => environments(:production), :managed => true, :build => true,
        :owner_type => "User", :root_pass => "xybxa6JUkz63w"
      refute host.valid?
      assert_equal "can't be blank", host.errors[:medium_id][0]
    end

    test "should save if owner_type is empty and Host is unmanaged" do
      host = Host.new :name => "myfullhost", :mac => "aabbecddeeff", :ip => "3.3.4.03", :medium => media(:one),
        :domain => domains(:mydomain), :operatingsystem => operatingsystems(:redhat), :subnet => subnets(:two), :puppet_proxy => smart_proxies(:puppetmaster),
        :architecture => architectures(:x86_64), :environment => environments(:production), :managed => false
      assert host.valid?
    end

    test "should import from external nodes output" do
      Setting[:Parametrized_Classes_in_ENC] = true
      Setting[:Enable_Smart_Variables_in_ENC] = true
      # create a dummy node
      Parameter.destroy_all
      host = Host.create :name => "myfullhost", :mac => "aabbacddeeff", :ip => "3.3.4.12", :medium => media(:one),
        :domain => domains(:mydomain), :operatingsystem => operatingsystems(:redhat), :subnet => subnets(:two),
        :architecture => architectures(:x86_64), :environment => environments(:production), :disk => "aaa",
        :puppet_proxy => smart_proxies(:puppetmaster)

      # dummy external node info
      nodeinfo = {"environment" => "production",
                  "parameters"=> {"puppetmaster"=>"puppet", "MYVAR"=>"value", "port" => "80",
                                  "ssl_port" => "443", "foreman_env"=> "production", "owner_name"=>"Admin User",
                                  "root_pw"=>"xybxa6JUkz63w", "owner_email"=>"admin@someware.com",
                                  "foreman_subnets"=>
      [{"network"=>"3.3.4.0",
        "name"=>"two",
        "gateway"=>nil,
        "mask"=>"255.255.255.0",
        "dns_primary"=>nil,
        "dns_secondary"=>nil,
        "from"=>nil,
        "to"=>nil,
        "boot_mode"=>"DHCP",
        "vlanid" => "41",
        "ipam"=>"DHCP"}],
        "foreman_interfaces"=>
      [{"mac"=>"aa:bb:ac:dd:ee:ff",
        "ip"=>"3.3.4.12",
        "type"=>"Interface",
        "name"=>'myfullhost.mydomain.net',
        "attrs"=>{},
        "virtual"=>false,
        "link"=>true,
        "identifier"=>nil,
        "managed"=>true,
        "primary"=>true,
        "provision"=>true,
        "subnet"=> {"network"=>"3.3.4.0",
                    "mask"=>"255.255.255.0",
                    "name"=>"two",
                    "gateway"=>nil,
                    "dns_primary"=>nil,
                    "dns_secondary"=>nil,
                    "from"=>nil,
                    "to"=>nil,
                    "boot_mode"=>"DHCP",
                    "vlanid" => "41",
                    "ipam"=>"DHCP"}}]},
                    "classes"=>{"apache"=>{"custom_class_param"=>"abcdef"}, "base"=>{"cluster"=>"secret"}} }

      host.importNode nodeinfo
      nodeinfo["parameters"]["special_info"] = "secret" # smart variable on apache

      info = host.info
      assert_includes info.keys, 'environment'
      assert_equal 'production', host.environment.name
      assert_includes info.keys, 'parameters'
      assert_includes info.keys, 'classes'
      assert_equal({ 'apache' => { 'custom_class_param' => 'abcdef' }, 'base' => { 'cluster' => 'secret' } }, info['classes'])
      parameters = info['parameters']
      assert_equal 'puppet', parameters['puppetmaster']
      assert_equal 'xybxa6JUkz63w', parameters['root_pw']
      assert_includes parameters.keys, 'foreman_subnets'
      assert_includes parameters.keys, 'foreman_interfaces'
      assert_equal '3.3.4.12', parameters['foreman_interfaces'].first['ip']
    end

    test "should import from non-parameterized external nodes output" do
      host = FactoryGirl.create(:host, :environment => environments(:production))
      host.importNode("environment" => "production", "classes" => ["apache", "base"], "parameters" => {})

      Setting[:Parametrized_Classes_in_ENC] = true
      Setting[:Enable_Smart_Variables_in_ENC] = true
      assert_equal ['apache', 'base'], host.info['classes'].keys
    end

    test "show be enabled by default" do
      host = Host.create :name => "myhost", :mac => "aabbccddeeff"
      assert host.enabled?
    end

    test "host can be disabled" do
      host = Host.create :name => "myhost", :mac => "aabbccddeeff"
      host.enabled = false
      host.save
      assert host.disabled?
    end

    test "a fqdn Host should be assigned to a domain if such domain exists" do
      domain = domains(:mydomain)
      host = Host.create :name => "host.mydomain.net", :mac => "aabbccddeaff", :ip => "2.3.04.03",
        :operatingsystem => operatingsystems(:redhat), :subnet => subnets(:one), :medium => media(:one),
        :architecture => architectures(:x86_64), :environment => environments(:production), :disk => "aaa"
      host.valid?
      assert_equal domain, host.domain
    end

    context 'associated config templates' do
      setup do
        @host = Host.create(:name => "host.mydomain.net", :mac => "aabbccddeaff",
                            :ip => "2.3.04.03",           :medium => media(:one),
                            :subnet => subnets(:one), :hostgroup => Hostgroup.find_by_name("Common"),
                            :architecture => Architecture.first, :disk => "aaa",
                            :environment => Environment.find_by_name("production"))
      end

      test "retrieves iPXE template if associated to the correct env and host group" do
        assert_equal ProvisioningTemplate.find_by_name("MyString"), @host.provisioning_template({:kind => "iPXE"})
      end

      test "retrieves provision template if associated to the correct host group only" do
        assert_equal ProvisioningTemplate.find_by_name("MyString2"), @host.provisioning_template({:kind => "provision"})
      end

      test "retrieves script template if associated to the correct OS only" do
        assert_equal ProvisioningTemplate.find_by_name("MyScript"), @host.provisioning_template({:kind => "script"})
      end

      test "retrieves finish template if associated to the correct environment only" do
        assert_equal ProvisioningTemplate.find_by_name("MyFinish"), @host.provisioning_template({:kind => "finish"})
      end

      test "available_template_kinds finds templates for a PXE host" do
        os_dt = FactoryGirl.create(:os_default_template,
                                   :template_kind=> TemplateKind.friendly.find('finish'))
        host  = FactoryGirl.create(:host, :operatingsystem => os_dt.operatingsystem)

        assert_equal [os_dt.provisioning_template], host.available_template_kinds('build')
      end

      test "available_template_kinds finds templates for an image host" do
        os_dt = FactoryGirl.create(:os_default_template,
                                   :template_kind=> TemplateKind.friendly.find('finish'))
        host  = FactoryGirl.create(:host, :on_compute_resource,
                                   :operatingsystem => os_dt.operatingsystem)
        FactoryGirl.create(:image, :uuid => 'abcde',
                           :compute_resource => host.compute_resource)
        host.compute_attributes = {:image_id => 'abcde'}

        assert_equal [os_dt.provisioning_template], host.available_template_kinds('image')
      end

      test "#render_template" do
        provision_template = @host.provisioning_template({:kind => "provision"})
        @host.expects(:load_template_vars)
        rendered_template = @host.render_template(provision_template)
        assert(rendered_template.include?("http://foreman.some.host.fqdn/unattended/finish"), "rendred template should parse foreman_url")
      end
    end

    test "handle_ca must not perform actions when the manage_puppetca setting is false" do
      h = FactoryGirl.create(:host)
      Setting[:manage_puppetca] = false
      h.expects(:initialize_puppetca).never
      h.expects(:setAutosign).never
      assert h.handle_ca
    end

    test "handle_ca must not perform actions when no Puppet CA proxy is associated even if associated with hostgroup" do
      hostgroup = FactoryGirl.create(:hostgroup, :with_puppet_orchestration, :with_domain, :with_os)
      h = FactoryGirl.create(:host, :managed, :with_environment, :hostgroup => hostgroup)
      Setting[:manage_puppetca] = true

      h.puppet_proxy_id = h.puppet_ca_proxy_id = nil
      h.save

      refute h.puppetca?

      h.expects(:initialize_puppetca).never
      assert h.handle_ca
    end

    test "handle_ca must not perform actions when no Puppet CA proxy is associated" do
      h = FactoryGirl.create(:host)
      Setting[:manage_puppetca] = true
      refute h.puppetca?
      h.expects(:initialize_puppetca).never
      assert h.handle_ca
    end

    test "handle_ca must call initialize, delete cert and add autosign methods" do
      h = FactoryGirl.create(:host, :with_puppet_orchestration)
      Setting[:manage_puppetca] = true
      assert h.puppetca?
      h.expects(:initialize_puppetca).returns(true)
      h.expects(:delCertificate).returns(true)
      h.expects(:setAutosign).returns(true)
      assert h.handle_ca
    end

    test "if the user toggles off the use_uuid_for_certificates option, revoke the UUID and autosign the hostname" do
      h = FactoryGirl.create(:host, :with_puppet_orchestration)
      Setting[:manage_puppetca] = true
      assert h.puppetca?

      Setting[:use_uuid_for_certificates] = false
      some_uuid = Foreman.uuid
      h.certname = some_uuid

      h.expects(:initialize_puppetca).returns(true)
      mock_puppetca = Object.new
      mock_puppetca.expects(:del_certificate).with(some_uuid).returns(true)
      mock_puppetca.expects(:set_autosign).with(h.name).returns(true)
      h.instance_variable_set("@puppetca", mock_puppetca)

      assert h.handle_ca
      assert_equal h.certname, h.name
    end

    test "if the user changes a hostname in non-use_uuid_for_cetificates mode, revoke the old hostname and autosign the new hostname" do
      Setting[:use_uuid_for_certificates] = false
      Setting[:manage_puppetca] = true

      h = FactoryGirl.create(:host, :with_puppet_orchestration)
      assert h.puppetca?

      old_name = 'oldhostname'
      h.certname = old_name

      h.expects(:initialize_puppetca).returns(true)
      mock_puppetca = Object.new
      mock_puppetca.expects(:del_certificate).with(old_name).returns(true)
      mock_puppetca.expects(:set_autosign).with(h.name).returns(true)
      h.instance_variable_set("@puppetca", mock_puppetca)

      assert h.handle_ca
      assert_equal h.certname, h.name
    end

    test "custom_disk_partition_with_erb" do
      h = FactoryGirl.create(:host)
      h.disk = "<%= template_name %>"
      assert h.save
      assert h.disk.present?
      assert_equal "Custom disk layout", h.diskLayout
    end

    test "custom_disk_partition_with_ptable" do
      h = FactoryGirl.create(:host, :managed)
      h.disk = ''
      h.ptable.stubs(:name).returns("some_name")
      h.ptable.stubs(:layout).returns("<%= template_name %>")
      assert h.save
      assert_equal "some_name", h.diskLayout
    end

    test "models are updated when host.model has no value" do
      h = FactoryGirl.create(:host)
      FactoryGirl.create(:fact_value, :value => 'superbox',:host => h,
                         :fact_name => FactoryGirl.create(:fact_name, :name => 'kernelversion'))
      assert_difference('Model.count') do
        facts = read_json_fixture('facts/facts.json')
        h.populate_fields_from_facts facts['facts']
      end
    end

    test "hostgroup should set default values for new host" do
      hg = hostgroups(:common)
      h  = Host.new

      h.architecture = architectures(:sparc)

      h.hostgroup = hg
      h.set_hostgroup_defaults

      assert_equal hg.operatingsystem, h.operatingsystem
      assert_equal architectures(:sparc), h.architecture
      # overwrite host attrs with values from hostgroup
      h.set_hostgroup_defaults true
      assert_equal hg.operatingsystem, h.operatingsystem
      assert_equal hg.architecture, h.architecture
    end

    test "host os attributes must be associated with the host os" do
      h = FactoryGirl.create(:host, :managed)
      h.architecture = architectures(:sparc)
      assert !h.os.architectures.include?(h.arch)
      assert !h.valid?
      assert_equal ["#{h.architecture} does not belong to #{h.os} operating system"], h.errors[:architecture_id]
    end

    test "host puppet classes must belong to the host environment" do
      h = FactoryGirl.create(:host, :with_environment)

      pc = puppetclasses(:three)
      h.puppetclasses << pc
      assert !h.environment.puppetclasses.map(&:id).include?(pc.id)
      assert !h.valid?
      assert_equal ["#{pc} does not belong to the #{h.environment} environment"], h.errors[:puppetclasses]
    end

    test "when changing host environment, its puppet classes should be verified" do
      h = FactoryGirl.create(:host, :environment => environments(:production))
      pc = puppetclasses(:one)
      h.puppetclasses << pc
      assert h.save
      h.environment = environments(:testing)
      assert !h.save
      assert_equal ["#{pc} does not belong to the #{h.environment} environment"], h.errors[:puppetclasses]
    end

    test "when setting host environment to nil, its puppet classes should be removed" do
      h = FactoryGirl.create(:host, :environment => environments(:production))
      pc = puppetclasses(:one)
      h.puppetclasses << pc
      assert h.save
      h.environment = nil
      h.save!
      assert_empty h.puppetclasses
    end

    test "when setting host environment to nil, its config groups should be removed" do
      h = FactoryGirl.create(:host, :environment => environments(:production))
      pc = config_groups(:one)
      h.config_groups << pc
      assert h.save
      h.environment = nil
      h.save!
      assert_empty h.config_groups
    end

    test "when saving a host, do not require a puppet environment" do
      h = FactoryGirl.build(:host, :environment => environments(:production), :puppet_proxy => nil)
      h.environment = nil
      assert h.valid?
    end

    test "when saving a host, require puppet environment if puppet master is set" do
      h = FactoryGirl.build(:host, :environment => environments(:production), :puppet_proxy => smart_proxies(:puppetmaster))
      h.environment = nil
      refute h.valid?
    end

    test "should not allow short root passwords for managed host in build mode" do
      h = FactoryGirl.create(:host, :managed)
      h.build = true
      h.root_pass = "2short"
      h.valid?
      assert h.errors[:root_pass].include?("should be 8 characters or more")
    end

    test "should allow build mode for managed hosts" do
      h = FactoryGirl.build(:host, :managed)
      assert h.valid?
      h.build = true
      assert h.valid?
    end

    test "should not allow build mode for unmanaged hosts" do
      h = FactoryGirl.build(:host)
      assert h.valid?
      h.build = true
      refute h.valid?
      assert h.errors[:build].include?("cannot be enabled for an unmanaged host")
    end

    test "should allow to save root pw" do
      h = FactoryGirl.create(:host, :managed)
      pw = h.root_pass
      h.root_pass = "12345678"
      h.hostgroup = nil
      assert h.save!
      assert_not_equal pw, h.root_pass
    end

    test "should allow to revert to default root pw" do
      Setting[:root_pass] = "$1$default$hCkak1kaJPQILNmYbUXhD0"
      h = FactoryGirl.create(:host, :managed)
      h.root_pass = "xybxa6JUkz63w"
      assert h.save
      h.root_pass = nil
      assert h.save!
      assert_equal h.root_pass, Setting[:root_pass]
    end

    test "should crypt the password and update it in the database" do
      unencrypted_password = "xybxa6JUkz63w"
      host = FactoryGirl.create(:host, :managed)
      host.hostgroup = nil
      host.root_pass = unencrypted_password
      assert host.save!
      first_password = host.root_pass

      # Make sure that the password gets encrypted in the DB, we don't care how it does that
      refute first_password.include?(unencrypted_password)

      # Check it changes
      host.root_pass = "12345678"
      assert host.save
      assert_not_equal first_password, host.root_pass
      # Encrypted passwords should have UTF-8 encoding
      assert_equal Encoding::UTF_8, host.root_pass.encoding
    end

    test "should pass through existing salt when saving root pw" do
      h = FactoryGirl.create(:host, :managed)
      pass = "$1$jmUiJ3NW$bT6CdeWZ3a6gIOio5qW0f1"
      h.root_pass = pass
      h.hostgroup = nil
      assert h.save
      assert_equal pass, h.root_pass
    end

    test "should base64-encode the root password and update it in the database" do
      unencrypted_password = "xybxa6JUkz63w"
      host = FactoryGirl.create(:host, :managed)
      host.hostgroup = nil
      host.operatingsystem.password_hash = 'Base64'
      host.root_pass = unencrypted_password
      assert host.save!
      assert_equal 'eHlieGE2SlVrejYzdw==', host.root_pass
      # Encrypted passwords should have UTF-8 encoding
      assert_equal Encoding::UTF_8, host.root_pass.encoding
    end

    test "should not reencode base64 passwords" do
      unencrypted_password = "xybxa6JUkz63w"
      host = FactoryGirl.create(:host, :managed)
      host.hostgroup = nil
      host.operatingsystem.password_hash = 'Base64'
      host.operatingsystem.save
      host.root_pass = unencrypted_password
      assert host.save!
      host.reload
      host.name = "whatever"
      assert host.save!
      assert_equal 'eHlieGE2SlVrejYzdw==', host.root_pass
      #then let's check that we can change root pass
      host.root_pass = "oh my pass"
      assert host.save!
      refute_equal host.root_pass, 'eHlieGE2SlVrejYzdw=='
    end

    test "should use hostgroup base64 root password without reencoding" do
      Setting[:root_pass] = "$1$default$hCkak1kaJPQILNmYbUXhD0"
      hg = FactoryGirl.create(:hostgroup, :with_os, :with_domain)
      hg.operatingsystem.update_attribute(:password_hash, 'Base64')
      hg.root_pass = "abcdefghi"
      hg.save!
      assert_equal "YWJjZGVmZ2hp", hg.root_pass

      h = FactoryGirl.create(:host, :managed, :hostgroup => hg, :operatingsystem => nil)
      h.root_pass = nil
      h.save!
      assert h.root_pass.present?
      assert_equal h.hostgroup.root_pass, h.root_pass
      assert_equal h.hostgroup.root_pass, h.read_attribute(:root_pass), 'should copy root_pass to host unmodified'
    end

    test "should use hostgroup root password" do
      Setting[:root_pass] = "$1$default$hCkak1kaJPQILNmYbUXhD0"
      h = FactoryGirl.create(:host, :managed, :with_hostgroup)
      h.hostgroup.update_attribute(:root_pass, "abc")
      h.root_pass = nil
      assert h.save
      assert h.root_pass.present?
      assert_equal h.hostgroup.root_pass, h.root_pass
      assert_equal h.hostgroup.root_pass, h.read_attribute(:root_pass), 'should copy root_pass to host'
    end

    test "should use a nested hostgroup parent root password" do
      Setting[:root_pass] = "$1$default$hCkak1kaJPQILNmYbUXhD0"
      h = FactoryGirl.create(:host, :managed, :with_hostgroup)
      g = h.hostgroup
      p = FactoryGirl.create(:hostgroup, :environment => h.environment)
      p.update_attribute(:root_pass, "abc")
      h.root_pass = nil
      g.root_pass = nil
      g.parent = p
      g.save
      assert h.save
      assert h.root_pass.present?
      assert_equal p.root_pass, h.root_pass
      assert_equal p.root_pass, h.read_attribute(:root_pass), 'should copy root_pass to host'
    end

    test "should use settings root password" do
      Setting[:root_pass] = "$1$default$hCkak1kaJPQILNmYbUXhD0"
      h = FactoryGirl.create(:host, :managed)
      h.root_pass = nil
      assert h.save
      assert h.root_pass.present?
      assert_equal Setting[:root_pass], h.root_pass
      assert_equal Setting[:root_pass], h.read_attribute(:root_pass), 'should copy root_pass to host'
    end

    test "should use settings root password when hostgroup has empty root password" do
      Setting[:root_pass] = "$1$default$hCkak1kaJPQILNmYbUXhD0"
      g = FactoryGirl.create(:hostgroup, :with_domain, :with_os, :root_pass => "")
      h = FactoryGirl.create(:host, :managed, :hostgroup => g)
      h.root_pass = ""
      h.save
      assert_valid h
      assert h.root_pass.present?
      assert_equal Setting[:root_pass], h.root_pass
      assert_equal Setting[:root_pass], h.read_attribute(:root_pass), 'should copy root_pass to host'
    end

    test "should validate pxe loader when provided" do
      host = Host.create :name => "myhostpxe", :mac => "aabbecddeeff", :ip => "2.3.4.3", :hostgroup => hostgroups(:common), :managed => true, :pxe_loader => "PXELinux BIOS"
      assert_equal "x86_64", host.architecture.name
      assert_equal "PXELinux BIOS", host.pxe_loader
      assert_empty host.errors.messages
      assert host.valid?
    end

    test "should save uuid on managed hosts" do
      Setting[:use_uuid_for_certificates] = true
      host = Host.create :name => "myhost1", :mac => "aabbecddeeff", :ip => "2.3.4.3", :hostgroup => hostgroups(:common), :managed => true
      assert host.valid?
      assert !host.new_record?
      assert_not_nil host.certname
      assert_not_equal host.name, host.certname
    end

    test "should not save uuid on non managed hosts" do
      Setting[:use_uuid_for_certificates] = true
      host = Host.create :name => "myhost1", :mac => "aabbecddeeff", :ip => "2.3.4.3", :hostgroup => hostgroups(:common), :managed => false
      assert host.valid?
      assert !host.new_record?
      assert_equal host.name, host.certname
    end

    test "should not save uuid when settings disable it" do
      Setting[:use_uuid_for_certificates] = false
      host = Host.create :name => "myhost1", :mac => "aabbecddeeff", :ip => "2.3.4.3", :hostgroup => hostgroups(:common), :managed => false
      assert host.valid?
      assert !host.new_record?
      assert_equal host.name, host.certname
    end

    test "all whitespace should be removed from hostname" do
      host = Host.create :name => "my host 1	", :mac => "aabbecddeeff", :ip => "2.3.4.3", :hostgroup => hostgroups(:common), :managed => false
      assert host.valid?
      assert !host.new_record?
      assert_equal "myhost1.mydomain.net", host.name
    end

    test "should have only one provision interface" do
      organization = FactoryGirl.create(:organization)
      location = FactoryGirl.create(:location)
      subnet = FactoryGirl.create(:subnet_ipv4, :organizations => [organization], :locations => [location])
      host = FactoryGirl.create(:host, :managed, :organization => organization,
                                :location => location, :subnet => subnet,
                                :ip => subnet.network.succ)
      host.interfaces_attributes = [
        { :name => "dummy-bootable2", :ip => "2.3.4.103",
          :mac => "aa:bb:cd:cd:ee:ff", :subnet_id => host.subnet_id,
          :type => 'Nic::Managed', :domain_id => host.domain_id,
          :provision => true } ]
      refute host.valid?
      assert_equal ['host already has provision interface'], host.errors['interfaces.provision']
      assert_equal 1, host.interfaces.count
    end

    test "#set_interfaces handles no interfaces" do
      host = FactoryGirl.create(:host, :hostgroup => FactoryGirl.create(:hostgroup))
      parser = stub(:ipmi_interface => {}, :interfaces => {}, :suggested_primary_interface => [ nil, nil ])
      host.set_interfaces(parser)
      assert host.primary_interface
      assert_empty host.primary_interface.mac
    end

    test "#set_interfaces updates primary physical interface" do
      host, parser = setup_host_with_nic_parser({:macaddress => '00:00:00:11:22:33', :virtual => false, :ipaddress => '10.0.0.200', :ipaddress6 => '2001:db8::2', :identifier => 'eth1'})
      host.update_attribute :mac, '00:00:00:11:22:33'
      host.update_attribute :ip, '10.0.0.100'
      host.update_attribute :ip6, '2001:db8::1'
      host.primary_interface.update_attribute :identifier, 'eth0'
      refute_nil host.primary_interface
      assert_equal '10.0.0.100', host.ip
      assert_equal '2001:db8::1', host.ip6

      # physical NICs with same MAC are skipped
      assert_no_difference 'Nic::Base.count' do
        host.set_interfaces(parser)
      end
      assert_equal '10.0.0.200', host.ip
      assert_equal '2001:db8::2', host.ip6
      assert_equal 'eth1', host.primary_interface.identifier
    end

    test "#set_interfaces updates existing physical interface" do
      host, parser = setup_host_with_nic_parser({:macaddress => '00:00:00:11:22:33', :virtual => false, :ipaddress => '10.0.0.200', :ipaddress6 => '2001:db8::2', :link => false})
      FactoryGirl.create(:nic_managed, :host => host, :mac => '00:00:00:11:22:33', :ip => '10.10.0.1', :ip6 => '2001:db8::1', :link => true)
      assert_no_difference 'Nic::Base.count' do
        host.set_interfaces(parser)
      end
      assert_equal '10.0.0.200', host.interfaces.where(:mac => '00:00:00:11:22:33').first.ip
      assert_equal '2001:db8::2', host.interfaces.where(:mac => '00:00:00:11:22:33').first.ip6
      refute host.interfaces.where(:mac => '00:00:00:11:22:33').first.link
    end

    test "#set_interfaces does not save when no changes made" do
      host, parser = setup_host_with_nic_parser({:macaddress => '00:00:00:11:22:33', :virtual => false, :ipaddress => '10.0.0.1', :ipaddress6 => '2001:db8::1', :link => true})
      host.primary_interface.update_attribute :mac, '00:00:00:11:22:33'
      host.primary_interface.update_attribute :ip, '10.0.0.1'
      host.primary_interface.update_attribute :ip6, '2001:db8::1'
      host.primary_interface.update_attribute :identifier, 'eth0'
      Nic::Base.any_instance.expects(:save).never
      assert_no_difference 'Nic::Base.count' do
        host.set_interfaces(parser)
      end
    end

    test "#set_interfaces updates existing physical interface by identifier" do
      host, parser = setup_host_with_nic_parser({:macaddress => '00:00:00:22:33:44', :identifier => 'eth0', :virtual => false, :ipaddress => '10.0.0.200', :ipaddress6 => '2001:db8::2', :link => false})
      host.managed = false
      host.primary_interface.update_attributes(:identifier => 'eth0', :mac => '00:00:00:11:22:33', :ip => '10.10.0.1', :ip6 => '2001:db8::1', :link => true)
      assert_no_difference 'Nic::Base.count' do
        host.set_interfaces(parser)
      end

      assert_equal '10.0.0.200', host.interfaces.where(:mac => '00:00:00:22:33:44').first.ip
      assert_equal '2001:db8::2', host.interfaces.where(:mac => '00:00:00:22:33:44').first.ip6
      assert_empty host.interfaces.where(:mac => '00:00:00:11:22:33')
      refute host.interfaces.where(:mac => '00:00:00:22:33:44').first.link
    end

    test "#set_interfaces updates existing physical interface by MAC address" do
      host, parser = setup_host_with_nic_parser({:macaddress => '00:00:00:11:22:33', :virtual => false, :ipaddress => '10.10.0.1', :ipaddress6 => '2001:db8::1'})

      # primary already existed so it's updated
      assert_no_difference 'host.interfaces(true).count' do
        host.set_interfaces(parser)
      end
      assert_equal '10.10.0.1', host.interfaces.where(:mac => '00:00:00:11:22:33').first.ip
      assert_equal '2001:db8::1', host.interfaces.where(:mac => '00:00:00:11:22:33').first.ip6
    end

    test "#set_interfaces creates new physical interface if none exists" do
      host, parser = setup_host_with_nic_parser({:macaddress => '00:00:00:11:22:34', :virtual => false, :ipaddress => '10.10.0.1', :ipaddress6 => '2001:db8::1'})
      host.managed = true

      assert_difference 'host.interfaces(true).count' do
        host.set_interfaces(parser)
      end
      assert_equal '10.10.0.1', host.interfaces.where(:mac => '00:00:00:11:22:34').first.ip
      assert_equal '2001:db8::1', host.interfaces.where(:mac => '00:00:00:11:22:34').first.ip6
    end

    test "#set_interfaces creates new interface with link up if no link fact specified" do
      host, parser = setup_host_with_nic_parser({:macaddress => '00:00:00:11:22:33', :virtual => false, :ipaddress => '10.10.0.1'})
      host.set_interfaces(parser)
      assert host.interfaces.where(:mac => '00:00:00:11:22:33').first.link
    end

    test "#set_interfaces creates new interface even if primary interface has same MAC" do
      host, parser = setup_host_with_nic_parser({:macaddress => '00:00:00:11:22:33', :virtual => true, :ipaddress => '10.10.0.1', :attached_to => 'eth0', :identifier => 'eth0_0'})
      host.update_attribute :mac, '00:00:00:11:22:33'
      host.update_attribute :ip, '10.0.0.100'

      assert_difference 'host.interfaces(true).count' do
        host.set_interfaces(parser)
      end
      assert_equal '10.0.0.100', host.ip
    end

    test "#set_interfaces creates new interface even if another virtual interface has same MAC but another identifier" do
      host, parser = setup_host_with_nic_parser({:macaddress => '00:00:00:11:22:33', :virtual => true, :ipaddress => '10.10.0.2', :identifier => 'eth0_1', :attached_to => 'eth0'})
      host.update_attribute :mac, '00:00:00:11:22:44'
      FactoryGirl.create(:nic_managed, :host => host, :mac => '00:00:00:11:22:33', :ip => '10.10.0.1', :virtual => true, :identifier => 'eth0_0', :attached_to => 'eth0', :name => 'second')

      assert_difference 'host.interfaces(true).count' do
        host.set_interfaces(parser)
      end
    end

    test "#set_interfaces updates existing virtual interface only if it has same MAC and identifier" do
      host, parser = setup_host_with_nic_parser({:macaddress => '00:00:00:11:22:33', :virtual => true, :ipaddress => '10.10.0.1', :attached_to => 'eth0', :identifier => 'eth0_0'})
      host.primary_interface.update_attribute :identifier, 'eth0'
      FactoryGirl.create(:nic_managed, :host => host, :mac => '00:00:00:11:22:33', :ip => '10.10.0.200', :virtual => true, :attached_to => 'eth0', :identifier => 'eth0_0')

      assert_no_difference 'host.interfaces(true).count' do
        host.set_interfaces(parser)
      end
      assert_equal '10.10.0.1', host.interfaces.where(:identifier => 'eth0_0').first.ip
    end

    test "#set_interfaces creates IPMI device if parameters are found" do
      host, parser = setup_host_with_ipmi_parser({:ipaddress => '192.168.0.1', :macaddress => '00:00:00:11:33:55'})

      assert_difference 'host.interfaces(true).count' do
        host.set_interfaces(parser)
      end
      bmc = host.interfaces.where(:type => 'Nic::BMC').first
      assert_equal '192.168.0.1', bmc.ip
      assert_equal '00:00:00:11:33:55', bmc.mac
    end

    test "#set_interfaces updates IPMI device if parameters are found and there's existing IPMI with same MAC" do
      host, parser = setup_host_with_ipmi_parser({:ipaddress => '192.168.0.1', :macaddress => '00:00:00:11:33:55'})
      FactoryGirl.create(:nic_bmc, :host => host, :mac => '00:00:00:11:33:55', :ip => '10.10.0.200', :virtual => false)

      assert_no_difference 'host.interfaces(true).count' do
        host.set_interfaces(parser)
      end
      bmcs = host.interfaces.where(:type => 'Nic::BMC')
      assert_equal 1, bmcs.count
      assert_equal '192.168.0.1', bmcs.first.ip
    end

    test "#set_interfaces updates associated virtuals identifier on identifier change" do
      # eth4 was renamed to eth5 (same MAC)
      host, parser = setup_host_with_nic_parser({:macaddress => '00:00:00:11:22:33', :ipaddress => '10.10.0.1', :virtual => false, :identifier => 'eth5'})
      FactoryGirl.create(:nic_managed, :host => host, :mac => '00:00:00:11:22:33', :ip => '10.10.0.1', :identifier => 'eth4')
      virtual = FactoryGirl.create(:nic_managed, :host => host, :mac => '00:00:00:11:22:33', :virtual => true, :ip => '10.10.0.2', :identifier => 'eth4.1', :attached_to => 'eth4')

      host.set_interfaces(parser)
      virtual.reload
      assert_equal 'eth5.1', virtual.identifier
      assert_equal 'eth5', virtual.attached_to
    end

    test "#set_interfaces does not update unassociated virtuals identifier on identifier change if original identifier was blank" do
      # interface with empty identifier was renamed to eth5 (same MAC)
      host = FactoryGirl.create(:host, :hostgroup => FactoryGirl.create(:hostgroup), :mac => '00:00:00:11:22:33')
      host.primary_interface.update_attribute :identifier, ''
      hash = { :bond0 => {:macaddress => '00:00:00:44:55:66', :ipaddress => '10.10.0.2', :virtual => true},
               :eth5 => {:macaddress => '00:00:00:11:22:33', :ipaddress => '10.10.0.1', :virtual => false, :identifier => 'eth5'}
      }.with_indifferent_access
      parser = stub(:interfaces => hash, :ipmi_interface => {}, :suggested_primary_interface => hash.to_a.first)
      bond0 = FactoryGirl.create(:nic_bond, :host => host, :mac => '00:00:00:44:55:66', :ip => '10.10.0.2', :identifier => 'bond0', :attached_to => '')

      host.set_interfaces(parser)
      bond0.reload
      assert_equal 'bond0', bond0.identifier
      assert_equal '', bond0.attached_to
    end

    test "set_interfaces updates associated virtuals identifier even on primary interface" do
      host, parser = setup_host_with_nic_parser({:macaddress => '00:00:00:11:22:33', :ipaddress => '10.10.0.1', :virtual => false, :identifier => 'eth1'})
      host.primary_interface.update_attribute :identifier, 'eth0'
      host.primary_interface.update_attribute :mac, '00:00:00:11:22:33'
      virtual = FactoryGirl.create(:nic_managed, :host => host, :mac => '00:00:00:11:22:33', :virtual => true, :ip => '10.10.0.2', :identifier => 'eth0.1', :attached_to => 'eth0')

      host.set_interfaces(parser)
      virtual.reload
      assert_equal 'eth1.1', virtual.identifier
      assert_equal 'eth1', virtual.attached_to
    end

    test "#set_interfaces matches bonds based on identifier and even updates its mac" do
      # interface with empty identifier was renamed to eth5 (same MAC)
      host = FactoryGirl.create(:host, :hostgroup => FactoryGirl.create(:hostgroup), :mac => '00:00:00:11:22:33')
      hash = { :bond0 => {:macaddress => 'aa:bb:cc:44:55:66', :ipaddress => '10.10.0.3', :virtual => true},
               :eth5 => {:macaddress => '00:00:00:11:22:33', :ipaddress => '10.10.0.1', :virtual => false, :identifier => 'eth5'}
      }.with_indifferent_access
      parser = stub(:interfaces => hash, :ipmi_interface => {}, :suggested_primary_interface => hash.to_a.first)
      bond0 = FactoryGirl.create(:nic_bond, :host => host, :mac => '00:00:00:44:55:66', :ip => '10.10.0.2', :identifier => 'bond0')

      host.set_interfaces(parser)
      host.interfaces.reload
      assert_equal 1, host.interfaces.bonds.size
      bond0.reload
      assert_equal 'aa:bb:cc:44:55:66', bond0.mac
      assert_equal '10.10.0.3', bond0.ip
    end

    test "#set_interfaces matches bridges based on identifier and even updates its mac" do
      # interface with empty identifier was renamed to eth5 (same MAC)
      host = FactoryGirl.create(:host, :hostgroup => FactoryGirl.create(:hostgroup), :mac => '00:00:00:11:22:33')
      hash = { :br0 => {:macaddress => 'aa:bb:cc:44:55:66', :ipaddress => '10.10.0.3', :virtual => true},
               :eth5 => {:macaddress => '00:00:00:11:22:33', :ipaddress => '10.10.0.1', :virtual => false, :identifier => 'eth5'}
      }.with_indifferent_access
      parser = stub(:interfaces => hash, :ipmi_interface => {}, :suggested_primary_interface => hash.to_a.first)
      br0 = FactoryGirl.create(:nic_bridge, :host => host, :mac => '00:00:00:44:55:66', :ip => '10.10.0.2', :identifier => 'br0')

      host.set_interfaces(parser)
      host.interfaces.reload
      assert_equal 1, host.interfaces.bridges.size
      br0.reload
      assert_equal 'aa:bb:cc:44:55:66', br0.mac
      assert_equal '10.10.0.3', br0.ip
    end

    test "#set_interfaces updates associated virtuals identifier on identifier change mutualy exclusively" do
      # eth4 was renamed to eth5 and eth5 renamed to eth4
      host = FactoryGirl.create(:host, :hostgroup => FactoryGirl.create(:hostgroup))
      hash = { :eth5 => {:macaddress => '00:00:00:11:22:33', :ipaddress => '10.10.0.1', :virtual => false},
               :eth4 => {:macaddress => '00:00:00:44:55:66', :ipaddress => '10.10.0.2', :virtual => false}
      }.with_indifferent_access
      parser = stub(:interfaces => hash, :ipmi_interface => {}, :suggested_primary_interface => hash.to_a.first)
      physical4 = FactoryGirl.create(:nic_managed, :host => host, :mac => '00:00:00:11:22:33', :ip => '10.10.0.1', :identifier => 'eth4')
      physical5 = FactoryGirl.create(:nic_managed, :host => host, :mac => '00:00:00:44:55:66', :ip => '10.10.0.2', :identifier => 'eth5')
      virtual4 = FactoryGirl.create(:nic_managed, :host => host, :mac => '00:00:00:11:22:33', :virtual => true, :ip => '10.10.0.10', :identifier => 'eth4.1', :attached_to => 'eth4')
      virtual5 = FactoryGirl.create(:nic_managed, :host => host, :mac => '00:00:00:44:55:66', :virtual => true, :ip => '10.10.0.20', :identifier => 'eth5.1', :attached_to => 'eth5')

      host.set_interfaces(parser)
      physical4.reload
      physical5.reload
      virtual4.reload
      virtual5.reload
      assert_equal 'eth5', physical4.identifier
      assert_equal 'eth4', physical5.identifier
      assert_equal 'eth5.1', virtual4.identifier
      assert_equal 'eth4.1', virtual5.identifier
      assert_equal 'eth5', virtual4.attached_to
      assert_equal 'eth4', virtual5.attached_to
    end

    test "#set_interfaces updates virtuals with :attached_to defined" do
      host = FactoryGirl.create(:host, :hostgroup => FactoryGirl.create(:hostgroup))
      FactoryGirl.create(:nic_managed, :host => host, :mac => '00:00:00:11:22:33', :ip => '10.10.0.1', :identifier => 'em1')
      virtual = FactoryGirl.create(:nic_managed, :host => host, :mac => '00:00:00:11:22:33', :virtual => true, :ip => '10.10.0.2', :identifier => 'bond0', :attached_to => 'em1')
      hash = { :em1 => {:macaddress => '00:00:00:11:22:33', :ipaddress => '10.10.0.1', :virtual => false},
               :bond0 => {:macaddress => '00:00:00:11:22:33', :ipaddress => '10.10.0.42', :virtual => true, :attached_to => nil}
      }.with_indifferent_access
      parser = stub(:interfaces => hash, :ipmi_interface => {}, :suggested_primary_interface => hash.to_a.last)

      host.set_interfaces(parser)
      virtual.reload
      assert_equal 'em1', virtual.attached_to
      assert_equal '10.10.0.42', virtual.ip
    end

    test "#set_interfaces does not allow two physical devices with same IP, it ignores the second" do
      host = FactoryGirl.create(:host, :hostgroup => FactoryGirl.create(:hostgroup))
      hash = { :eth0 => {:macaddress => '00:00:00:55:66:77', :ipaddress => '10.10.0.1', :virtual => false },
               :eth1 => {:macaddress => '00:00:00:11:22:33', :ipaddress => '10.10.0.1', :virtual => false },
               :eth2 => {:macaddress => '00:00:00:44:55:66', :ipaddress => '10.10.0.2', :virtual => false }
      }.with_indifferent_access
      parser = stub(:interfaces => hash, :ipmi_interface => {}, :suggested_primary_interface => hash.to_a.first)

      host.set_interfaces(parser)
      host.reload
      assert_includes host.interfaces.map(&:identifier), 'eth2'
      assert_includes host.interfaces, host.primary_interface
      refute_includes host.interfaces.map(&:identifier), 'eth1'
      assert_equal 2, host.interfaces.size
    end

    test "#set_interfaces creates bond interfaces according to identifier" do
      host = FactoryGirl.create(:host, :hostgroup => FactoryGirl.create(:hostgroup))
      hash = {
        :eth1 => {:macaddress => '00:00:00:11:22:33', :ipaddress => '', :virtual => false},
        :bond0 => {:macaddress => '00:00:00:11:22:33', :ipaddress => '10.10.0.1', :virtual => true}
      }.with_indifferent_access
      parser = stub(:interfaces => hash, :ipmi_interface => {}, :suggested_primary_interface => hash.to_a.first)

      host.set_interfaces(parser)
      host.reload
      assert_includes host.interfaces.map(&:identifier), 'eth1'
      assert_includes host.interfaces.map(&:identifier), 'bond0'
      assert_equal 2, host.interfaces.size
      assert_kind_of Nic::Bond, host.interfaces.find_by_identifier('bond0')
      assert_kind_of Nic::Managed, host.interfaces.find_by_identifier('eth1')
    end

    test "host can't have more interfaces with the same identifier" do
      host = FactoryGirl.build(:host, :managed)
      host.primary_interface.identifier = 'eth0'
      nic = host.interfaces.build(:identifier => 'eth0')
      refute host.valid?
      assert nic.errors[:identifier].present?
      assert host.errors[:interfaces].present?
      nic.identifier = 'eth1'
      host.valid?
      refute_includes nic.errors.keys, :identifier
      refute_includes host.errors.keys, :interfaces
    end

    # Token tests

    context "tokens are enabled" do
      setup do
        Setting[:token_duration] = 30
      end

      test "built should clean tokens" do
        h = FactoryGirl.create(:host, :managed)
        h.create_token(:value => "aaaaaa", :expires => Time.now.utc)
        assert_equal Token.all.size, 1
        h.expire_token
        assert_equal Token.all.size, 0
      end

      test "hosts should be able to retrieve their token if one exists" do
        h = FactoryGirl.create(:host, :managed)
        assert_equal Token.first, h.token
      end

      test "a token can be matched to a host" do
        h = FactoryGirl.create(:host, :managed)
        h.create_token(:value => "aaaaaa", :expires => Time.now.utc + 1.minutes)
        assert_equal h, Host.for_token("aaaaaa").first
      end

      test "a token cannot be matched to a host when expired" do
        h = FactoryGirl.create(:host, :managed)
        h.create_token(:value => "aaaaaa", :expires => 1.minutes.ago)
        refute Host.for_token("aaaaaa").first
      end

      test "deleting an host with an expired token does not cause a Foreign Key error" do
        h = FactoryGirl.create(:host, :managed)
        h.create_token(:value => "aaaaaa", :expires => 5.minutes.ago)
        assert_nothing_raised(ActiveRecord::InvalidForeignKey) {h.reload.destroy}
      end

      test "token_expired? should be true if expiration date is in the past" do
        h = FactoryGirl.create(:host, :managed)
        h.create_token(:value => "aaaaaa", :expires => Time.now.utc - 1)
        assert_equal h.token_expired?, true
      end

      test "token_expired? should be false if expiration date is in the future" do
        h = FactoryGirl.create(:host, :managed)
        h.create_token(:value => "aaaaaa", :expires => Time.now.utc + 30)
        assert_equal h.token_expired?, false
      end
    end

    context "tokens are disabled" do
      setup do
        Setting[:token_duration] = 0
      end

      test "built should clean tokens even when tokens are disabled" do
        h = FactoryGirl.create(:host, :managed)
        h.create_token(:value => "aaaaaa", :expires => Time.now.utc)
        assert_equal Token.all.size, 1
        h.expire_token
        assert_equal Token.all.size, 0
      end

      test "token should return false when tokens are disabled or invalid" do
        h = FactoryGirl.create(:host, :managed)
        assert_equal h.token, nil
        Setting[:token_duration] = 30
        h.reload
        assert_equal h.token, nil
      end
    end

    test "can search hosts by hostgroup" do
      #setup - add parent to hostgroup :common (not in fixtures, since no field parent_id)
      hostgroup = hostgroups(:db)
      parent_hostgroup = hostgroups(:common)
      hostgroup.parent_id = parent_hostgroup.id
      assert hostgroup.save!

      FactoryGirl.create(:host, :hostgroup => hostgroup)
      # search hosts by hostgroup label
      hosts = Host.search_for("hostgroup_title = #{hostgroup.title}")
      assert_equal 1, hosts.count
      assert_equal hosts.first.hostgroup_id, hostgroup.id
    end

    test "can search hosts by parent hostgroup and its descendants" do
      #setup - add parent to hostgroup :common (not in fixtures, since no field parent_id)
      hostgroup = hostgroups(:db)
      parent_hostgroup = hostgroups(:common)
      hostgroup.parent_id = parent_hostgroup.id
      assert hostgroup.save!

      FactoryGirl.create(:host, :hostgroup => hostgroup)
      FactoryGirl.create(:host, :hostgroup => parent_hostgroup)
      # search hosts by parent hostgroup label
      hosts = Host::Managed.search_for("parent_hostgroup = Common")
      assert_equal hosts.count, 2
      assert_equal ["Common", "Common/db"].sort, hosts.map { |h| h.hostgroup.title }.sort
    end

    test "can search hosts by numeric and string facts" do
      host = FactoryGirl.create(:host, :hostname => 'num001.example.com')
      host.import_facts({:architecture => "x86_64", :interfaces => 'eth0', :operatingsystem => 'RedHat-test', :operatingsystemrelease => '6.2',:memory_mb => "64498",:custom_fact => "find_me"})

      hosts = Host::Managed.search_for("facts.memory_mb > 112889")
      assert_equal hosts.count, 0

      hosts = Host::Managed.search_for("facts.memory_mb > 6544")
      assert_equal hosts.count, 1
      assert_equal ["num001.example.com"], hosts.map { |h| h.name }.sort

      hosts = Host::Managed.search_for("facts.memory_mb ~ 64498")
      assert_equal hosts.count, 1
      assert_equal ["num001.example.com"], hosts.map { |h| h.name }.sort

      hosts = Host::Managed.search_for("facts.custom_fact = find_me")
      assert_equal hosts.count, 1
      assert_equal ["num001.example.com"], hosts.map { |h| h.name }.sort

      hosts = Host::Managed.search_for("facts.memory_mb > 6544 and facts.custom_fact = find_me")
      assert_equal hosts.count, 1
      assert_equal ["num001.example.com"], hosts.map { |h| h.name }.sort

      hosts = Host::Managed.search_for("facts.custom_fact ~ %nd_me")
      assert_equal hosts.count, 1
      assert_equal ["num001.example.com"], hosts.map { |h| h.name }.sort

      hosts = Host::Managed.search_for("facts.custom_fact ~ nd_m")
      assert_equal hosts.count, 1
      assert_equal ["num001.example.com"], hosts.map { |h| h.name }.sort
    end

    test "search by fact name is not vulnerable to SQL injection in name" do
      host = FactoryGirl.create(:host, :with_facts, :fact_count => 1)
      query = "facts.a'b = c or facts.#{host.facts.keys.first} = #{host.facts.values.first}"
      assert_equal [host], Host::Managed.search_for(query)
    end

    test "search by fact name is not vulnerable to SQL injection in value" do
      host = FactoryGirl.create(:host, :with_facts, :fact_count => 1)
      query = "facts.a = \"a'b\" or facts.#{host.facts.keys.first} = #{host.facts.values.first}"
      assert_equal [host], Host::Managed.search_for(query)
    end

    test "non-admin user with edit_hosts permission can update interface" do
      @one = users(:one)
      # add permission for user :one
      as_admin do
        filter = FactoryGirl.build(:filter)
        filter.permissions = [ Permission.find_by_name('edit_hosts') ]
        filter.save!
        role = Role.where(:name => "testing_role").first_or_create
        role.filters = [ filter ]
        role.save!
        @one.roles = [ role ]
        @one.save!
      end
      h = FactoryGirl.create(:host, :managed)
      assert h.interfaces.create :mac => "cabbccddeeff", :host => h, :type => 'Nic::BMC',
        :provider => "IPMI", :username => "root", :password => "secret", :ip => "10.35.19.35",
        :identifier => 'eth2'
      as_user :one do
        assert h.update_attributes!("interfaces_attributes" => {"0" => {"mac"=>"59:52:10:1e:45:16"}})
      end
    end

    context "built notifications" do
      let(:host) { FactoryGirl.build(:host, :managed, :owner => User.current) }

      setup do
        ActionMailer::Base.deliveries = []
        User.current.mail_notifications << MailNotification[:host_built]
      end

      test "is sent notification when installed" do
        host.built(true)
        email = ActionMailer::Base.deliveries.detect { |mail| mail.subject =~ /Host #{host} is built/ }
        assert email
        assert_match /Your host has finished/, email.body.encoded
      end

      test "is not sent when not installed" do
        host.built(false)
        assert_empty ActionMailer::Base.deliveries
      end
    end

    test "can auto-complete searches by host name" do
      as_admin do
        completions = Host::Managed.complete_for("name =")
        Host::Managed.all.each do |h|
          assert completions.include?("name = #{h.name}"), "completion missing: #{h}"
        end
      end
    end

    test "can auto-complete searches by facts" do
      as_admin do
        completions = Host::Managed.complete_for("facts.")
        FactName.order(:name).each do |fact|
          assert completions.include?(" facts.#{fact.name} "), "completion missing: #{fact}"
        end
      end
    end

    test "can auto-complete user searches by current_user" do
      as_admin do
        completions = Host::Managed.complete_for("user.login =")
        assert completions.include?("user.login = current_user"), "completion missing: current_user"
      end
    end

    test "can auto-complete owner searches by current_user" do
      as_admin do
        completions = Host::Managed.complete_for("owner = ")
        assert completions.include?("owner = current_user"), "completion missing: current_user"
      end
    end

    test "should accept lookup_values_attributes" do
      h = FactoryGirl.create(:host)
      as_admin do
        assert_difference "LookupValue.count" do
          assert h.update_attributes(:lookup_values_attributes => {"0" => {:lookup_key_id => lookup_keys(:one).id, :value => "8080" }})
        end
      end
    end

    test "can search hosts by params" do
      host = FactoryGirl.create(:host, :with_parameter)
      parameter = host.parameters.first
      results = Host.search_for(%{params.#{parameter.name} = "#{parameter.value}"})
      assert_equal 1, results.count
      assert_equal parameter.value, results.first.params[parameter.name]
    end

    test "can search hosts by current_user" do
      FactoryGirl.create(:host)
      results = Host.search_for("owner = current_user")
      assert_equal 1, results.count
      assert_equal results[0].owner, User.current
    end

    test "can search hosts by owner" do
      FactoryGirl.create(:host)
      results = Host.search_for("owner = " + User.current.login)
      assert_equal User.current.hosts.count, results.count
      assert_equal results[0].owner, User.current
    end

    test "search by user returns only the relevant hosts" do
      host = nil
      as_user :one do
        host = FactoryGirl.create(:host)
      end
      refute_equal User.current, host.owner
      results = Host.search_for("owner = " + User.current.login)
      refute results.include?(host)
    end

    test "search by params returns only the relevant hosts" do
      hg = hostgroups(:common)
      host = FactoryGirl.create(:host, :hostgroup => hg)
      host2 = FactoryGirl.create(:host, :hostgroup => nil)
      parameter = hg.group_parameters.first
      results = Host.search_for(%{params.#{parameter.name} = "#{parameter.value}"})
      assert results.include?(host)
      refute results.include?(host2)
    end

    test "can search hosts by domain connected to their primary interface" do
      host = FactoryGirl.create(:host, :managed)
      domain = host.domain
      domain.domain_parameters << DomainParameter.create(:name => "animal", :value => "dog")
      parameter = domain.domain_parameters.first
      results = Host.search_for(%{params.#{parameter.name} = "#{parameter.value}"})
      assert results.include?(host)
    end

    test "can search hosts by inherited params from a hostgroup" do
      hg = hostgroups(:common)
      host = FactoryGirl.create(:host, :hostgroup => hg)
      parameter = hg.group_parameters.first
      results = Host.search_for(%{params.#{parameter.name} = "#{parameter.value}"})
      assert results.include?(host)
      assert_equal parameter.value, results.find(host.id).params[parameter.name]
    end

    test "can search hosts by inherited params from a parent hostgroup" do
      parent_hg = hostgroups(:common)
      hg = FactoryGirl.create(:hostgroup, :parent => parent_hg)
      host = FactoryGirl.create(:host, :hostgroup => hg)
      parameter = parent_hg.group_parameters.first
      results = Host.search_for(%{params.#{parameter.name} = "#{parameter.value}"})
      assert results.include?(host)
      assert_equal parameter.value, results.find(host.id).params[parameter.name]
    end

    test "Correctly find hosts with overridden parameter values" do
      host1 = FactoryGirl.create(:host)
      host2 = FactoryGirl.create(:host)
      parameter = FactoryGirl.create(:parameter)
      override = FactoryGirl.create(:host_parameter, name: parameter.name, value: "different", host: host1)

      results = Host.search_for(%{params.#{parameter.name} = "#{parameter.value}"})
      assert results.include?(host2)
      refute results.include?(host1)

      results = Host.search_for(%{params.#{parameter.name} = "#{override.value}"})
      assert results.include?(host1)
      refute results.include?(host2)
    end

    test "can search hosts by smart proxy" do
      host = FactoryGirl.create(:host)
      proxy = FactoryGirl.create(:puppet_and_ca_smart_proxy)
      results = Host.search_for("smart_proxy = #{proxy.name}")
      assert_equal 0, results.count
      host.update_attribute(:puppet_proxy_id, proxy.id)
      results = Host.search_for("smart_proxy = #{proxy.name}")
      assert_equal 1, results.count
      assert results.include?(host)
      #the results should not change even if the host has multiple connections to same proxy
      host.update_attribute(:puppet_ca_proxy_id, proxy.id)
      results2 = Host.search_for("smart_proxy = #{proxy.name}")
      assert_equal results, results2
    end

    test "can search hosts by puppet class" do
      host = FactoryGirl.create(:host, :with_puppetclass)
      results = Host.search_for("class = #{host.puppetclasses.first.name}")
      assert_equal 1, results.count
      assert_equal host.puppetclasses.first, results.first.puppetclasses.first
    end

    test "can search hosts by inherited puppet class from a hostgroup" do
      hg = FactoryGirl.create(:hostgroup, :with_puppetclass)
      FactoryGirl.create(:host, :hostgroup => hg, :environment => hg.environment)
      results = Host.search_for("class = #{hg.puppetclasses.first.name}")
      assert_equal 1, results.count
      assert_equal 0, results.first.puppetclasses.count
      assert_equal hg.puppetclasses.first, results.first.hostgroup.puppetclasses.first
    end

    test "can search hosts by inherited puppet class from a parent hostgroup" do
      parent_hg = FactoryGirl.create(:hostgroup, :with_puppetclass)
      hg = FactoryGirl.create(:hostgroup, :parent => parent_hg)
      FactoryGirl.create(:host, :hostgroup => hg, :environment => hg.environment)
      results = Host.search_for("class = #{parent_hg.puppetclasses.first.name}")
      assert_equal 1, results.count
      assert_equal 0, results.first.puppetclasses.count
      assert_equal 0, results.first.hostgroup.puppetclasses.count
      assert_equal parent_hg.puppetclasses.first, results.first.hostgroup.parent.puppetclasses.first
    end

    test "can search hosts by puppet class from config group in parent hostgroup" do
      hostgroup = FactoryGirl.create(:hostgroup, :with_config_group)
      host = FactoryGirl.create(:host, :hostgroup => hostgroup, :environment => hostgroup.environment)
      puppetclass = hostgroup.config_groups.first.puppetclasses.first
      results = Host.search_for("class = #{puppetclass.name}")
      assert_equal 1, results.count
      assert_equal host, results.first
    end

    test "should update puppet_proxy_id to the id of the validated proxy" do
      sp = smart_proxies(:puppetmaster)
      raw = read_json_fixture('facts/facts_with_caps.json')
      host = Host.import_host(raw['name'], 'puppet', nil, sp.id)
      assert host.import_facts(raw['facts'])
      assert_equal sp.id, Host.find_by_name('sinn1636.lan').puppet_proxy_id
    end

    test "should not update puppet_proxy_id if it was not puppet upload" do
      sp = smart_proxies(:puppetmaster)
      raw = read_json_fixture('facts/facts_with_caps.json')
      host = Host.import_host(raw['name'], 'chef', nil, sp.id)
      assert_nil host.puppet_proxy_id
    end

    test "shouldn't update puppet_proxy_id if it has been set" do
      Host.new(:name => 'sinn1636.lan', :puppet_proxy_id => smart_proxies(:puppetmaster).id).save(:validate => false)
      sp = smart_proxies(:puppetmaster)
      raw = read_json_fixture('facts/facts_with_certname.json')
      host = Host.import_host(raw['name'], 'puppet', nil, sp.id)
      assert host.import_facts(raw['facts'])
      assert_equal smart_proxies(:puppetmaster).id, Host.find_by_name('sinn1636.lan').puppet_proxy_id
    end

    # Ip validations
    test "unmanaged hosts don't require an IPv4 or IPv6" do
      host = FactoryGirl.build(:host)
      refute host.require_ip4_validation?
      refute host.require_ip6_validation?
    end

    test "CRs without IP attribute don't require an IP" do
      Setting[:token_duration] = 30 #enable tokens so that we only test the CR
      host = FactoryGirl.build(:host, :managed,
                          :compute_resource => compute_resources(:one),
                          :compute_attributes => {:fake => "data"})
      refute host.require_ip4_validation?
      refute host.require_ip6_validation?
    end

    test "CRs with IP attribute and a DNS-enabled domain do not require an IP" do
      Setting[:token_duration] = 30 #enable tokens so that we only test the CR
      host = FactoryGirl.build(:host, :managed, :domain => domains(:mydomain),
                          :compute_resource => compute_resources(:openstack),
                          :compute_attributes => {:fake => "data"})
      refute host.require_ip4_validation?
      refute host.require_ip6_validation?
    end

    test "hosts with a IPv4 DNS-enabled Domain do require an IPv4 address" do
      Setting[:token_duration] = 30 #enable tokens so that we only test the domain
      host = FactoryGirl.build(:host, :managed, :domain => domains(:mydomain))
      assert host.require_ip4_validation?
      refute host.require_ip6_validation?
    end

    test "hosts with a DNS-enabled Domain without IPv4 do require an IPv6 address" do
      Setting[:token_duration] = 30 #enable tokens so that we only test the domain
      host = FactoryGirl.build(:host, :managed, :with_ipv6, :domain => domains(:mydomain))
      refute host.require_ip4_validation?
      assert host.require_ip6_validation?
    end

    test "hosts without a DNS-enabled Domain don't require an IP" do
      Setting[:token_duration] = 30 #enable tokens so that we only test the domain
      host = FactoryGirl.build(:host, :managed, :domain => domains(:useless))
      refute host.require_ip4_validation?
      refute host.require_ip6_validation?
    end

    test "hosts with a DNS-enabled Subnet do require an IPv4 address" do
      Setting[:token_duration] = 30 #enable tokens so that we only test the subnet
      host = FactoryGirl.build(:host, :managed, :subnet => FactoryGirl.build(:subnet_ipv4, :dns))
      assert host.require_ip4_validation?
      refute host.require_ip6_validation?
    end

    test "hosts with a DHCP-enabled Subnet do require an IP" do
      Setting[:token_duration] = 30 #enable tokens so that we only test the subnet
      host = FactoryGirl.build(:host, :managed, :subnet => FactoryGirl.build(:subnet_ipv4, :dhcp))
      assert host.require_ip4_validation?
      refute host.require_ip6_validation?
    end

    test "hosts without a DNS/DHCP-enabled Subnet don't require an IP" do
      Setting[:token_duration] = 30 #enable tokens so that we only test the subnet
      host = FactoryGirl.build(:host, :managed, :subnet => FactoryGirl.build(:subnet_ipv4, :dhcp => nil, :dns => nil))
      refute host.require_ip4_validation?
      refute host.require_ip6_validation?
    end

    test "hosts with a DNS-enabled IPv6 Subnet require an IPv6 but don't require an IPv4 address" do
      Setting[:token_duration] = 30 #enable tokens so that we only test the subnet
      host = FactoryGirl.build(:host, :managed,
                               :subnet => FactoryGirl.build(:subnet_ipv4, :dhcp => nil, :dns => nil),
                               :subnet6 => FactoryGirl.build(:subnet_ipv6, :dns))
      refute host.require_ip4_validation?
      assert host.require_ip6_validation?
    end

    test "with tokens enabled hosts don't require an IPv4 or IPv6 address" do
      Setting[:token_duration] = 30
      host = FactoryGirl.build(:host, :managed)
      refute host.require_ip4_validation?
      refute host.require_ip6_validation?
    end

    test "with tokens disabled PXE build hosts do require an IPv4 address" do
      host = FactoryGirl.build(:host, :managed)
      host.expects(:pxe_build?).twice.returns(true)
      host.stubs(:image_build?).returns(false)
      assert host.require_ip4_validation?
      refute host.require_ip6_validation?
    end

    test "with tokens disabled PXE build IPv6 hosts do not require an IPv4 but a IPv6 address" do
      host = FactoryGirl.build(:host, :managed, :with_ipv6)
      host.expects(:pxe_build?).twice.returns(true)
      host.stubs(:image_build?).returns(false)
      refute host.require_ip4_validation?
      assert host.require_ip6_validation?
    end

    test "tokens disabled doesn't require an IPv4 or IPv6 address for image hosts" do
      host = FactoryGirl.build(:host, :managed)
      host.expects(:pxe_build?).twice.returns(false)
      host.expects(:image_build?).twice.returns(true)
      image = stub()
      image.expects(:user_data?).twice.returns(false)
      host.stubs(:image).returns(image)
      refute host.require_ip4_validation?
      refute host.require_ip6_validation?
    end

    test "tokens disabled requires an IPv4 address for image hosts with user data" do
      host = FactoryGirl.build(:host, :managed)
      host.expects(:pxe_build?).twice.returns(false)
      host.expects(:image_build?).twice.returns(true)
      image = stub()
      image.expects(:user_data?).twice.returns(true)
      host.stubs(:image).returns(image)
      assert host.require_ip4_validation?
      refute host.require_ip6_validation?
    end

    test "tokens disabled requires only an IPv6 address for image hosts with user data and IPv6 address" do
      host = FactoryGirl.build(:host, :managed, :with_ipv6)
      host.expects(:pxe_build?).twice.returns(false)
      host.expects(:image_build?).twice.returns(true)
      image = stub()
      image.expects(:user_data?).twice.returns(true)
      host.stubs(:image).returns(image)
      refute host.require_ip4_validation?
      assert host.require_ip6_validation?
    end

    test "test tokens are not created until host is saved" do
      class Host::Test < Host::Base
        def lookup_value_match
          'no_match'
        end

        def to_managed!
          host       = self.becomes(::Host::Managed)
          host.type  = 'Host::Managed'
          host.build = true
          host
        end
      end
      Setting[:token_duration] = 30 #enable tokens so that we only test the subnet
      test_host    = Host::Test.create(:name => 'testhost', :interfaces => [FactoryGirl.build(:nic_primary_and_provision)])
      managed_host = test_host.to_managed!
      assert_empty Token.where(:host_id => managed_host.id)
    end

    test "compute attributes are populated by hardware profile from hostgroup" do
      # hostgroups(:common) fixture has compute_profiles(:one)
      host = FactoryGirl.build(:host, :managed,
        :hostgroup => hostgroups(:common),
        :compute_resource => compute_resources(:ec2),
        :organization => nil,
        :location => nil)
      host.expects(:queue_compute_create)
      assert host.valid?, host.errors.full_messages.to_sentence
      assert_equal compute_attributes(:one).vm_attrs, host.compute_attributes
    end

    test "compute attributes are populated by hardware profile passed to host" do
      host = FactoryGirl.build(:host, :managed,
        :compute_resource => compute_resources(:ec2),
        :compute_profile => compute_profiles(:two),
        :organization => nil,
        :location => nil)
      host.expects(:queue_compute_create)
      assert host.valid?, host.errors.full_messages.to_sentence
      assert_equal compute_attributes(:three).vm_attrs, host.compute_attributes
    end
  end # end of context "location or organizations are not enabled"

  test "should not save if owner taxonomies do not match host configuration" do
    org1 = FactoryGirl.create(:organization)
    loc1 = FactoryGirl.create(:location)
    user = FactoryGirl.create(:user, :organizations => [], :locations => [])
    host = FactoryGirl.build(:host, :organization => org1, :location => loc1, :owner => user)

    original_loc, SETTINGS[:locations_enabled] = SETTINGS[:locations_enabled], true
    original_org, SETTINGS[:organizations_enabled] = SETTINGS[:organizations_enabled], true
    refute host.valid?
    assert_operator 2, :<=, host.errors[:is_owned_by].size
    SETTINGS[:locations_enabled] = original_loc
    SETTINGS[:organizations_enabled] = original_org
  end

  test "#capabilities returns capabilities from compute resource" do
    host = FactoryGirl.create(:host, :compute_resource => compute_resources(:one))
    host.compute_resource.expects(:capabilities).returns([:build, :image])
    assert_equal [:build, :image], host.capabilities
  end

  test "#capabilities on bare metal returns build" do
    host = FactoryGirl.create(:host)
    host.compute_resource = nil
    assert_equal [:build], host.capabilities
  end

  test "#provision_method cannot be set to invalid type" do
    host = FactoryGirl.create(:host, :managed)
    host.provision_method = 'foobar'
    host.stubs(:provision_method_in_capabilities).returns(true)
    host.valid?
    assert host.errors[:provision_method].include?('is unknown')
  end

  test "#provision_method doesn't matter on unmanaged hosts" do
    host = FactoryGirl.create(:host)
    host.managed = false
    host.provision_method = 'foobar'
    assert host.valid?
  end

  test "#provision_method must be within capabilities" do
    host = FactoryGirl.create(:host, :managed, :with_environment)
    host.provision_method = 'image'
    host.expects(:capabilities).returns([:build])
    host.valid?
    assert host.errors[:provision_method].include?('is an unsupported provisioning method')
  end

  test "#provision_method cannot be updated for existing host" do
    host = FactoryGirl.create(:host, :managed)
    host.provision_method = 'image'
    refute host.save
    assert host.errors[:provision_method].include?("can't be updated after host is provisioned")
  end

  test "#provision_methods must include build and image by default" do
    assert_includes Host::Managed.provision_methods.keys, 'build'
    assert_includes Host::Managed.provision_methods.keys, 'image'
  end

  test 'validation of a host should work with a newly registered provision method' do
    host = FactoryGirl.build(:host, :managed, :provision_method => 'awesome')
    host.stubs(:capabilities).returns([:build, :awesome])
    refute_valid host
    assert host.errors[:provision_method].include?('is unknown')
    Foreman::Plugin.register :awesome_provision do
      name 'Awesome provision'
      provision_method 'awesome', 'Awesomeness Based'
    end
    assert_valid host
  end

  test "#image_build? must be true when provision_method is image" do
    host = FactoryGirl.create(:host, :managed)
    host.provision_method = 'image'
    assert host.image_build?
    refute host.pxe_build?
  end

  test "#pxe_build? must be true when provision_method is build" do
    host = FactoryGirl.create(:host, :managed)
    host.provision_method = 'build'
    assert host.pxe_build?
    refute host.image_build?
  end

  test "classes_in_groups should return the puppetclasses of a config group only if it is in host environment" do
    group1 = config_groups(:one)
    group2 = config_groups(:two)
    host = FactoryGirl.create(:host,
                              :location => taxonomies(:location1),
                              :organization => taxonomies(:organization1),
                              :environment => environments(:production),
                              :config_groups => [group1, group2])
    group_classes = host.classes_in_groups
    # four classes in config groups, all are in same environment
    assert_equal 4, (group1.puppetclasses + group2.puppetclasses).uniq.count
    assert_equal ['chkmk', 'nagios', 'pam', 'auth'].sort, group_classes.map(&:name).sort
  end

  test "should return all classes for environment only" do
    host = FactoryGirl.create(:host,
                              :location => taxonomies(:location1),
                              :organization => taxonomies(:organization1),
                              :environment => environments(:production),
                              :config_groups => [config_groups(:one), config_groups(:two)],
                              :puppetclasses => [puppetclasses(:one)])
    all_classes = host.classes
    # four classes in config groups plus one manually added
    assert_equal 5, all_classes.count
    assert_equal ['base', 'chkmk', 'nagios', 'pam', 'auth'].sort, all_classes.map(&:name).sort
    assert_equal all_classes, host.all_puppetclasses
  end

  test "search hostgroups by config group" do
    config_group = config_groups(:one)
    host = FactoryGirl.create(:host,
                              :location => taxonomies(:location1),
                              :organization => taxonomies(:organization1),
                              :environment => environments(:production),
                              :config_groups => [config_groups(:one)])
    hosts = Host::Managed.search_for("config_group = #{config_group.name}")
    assert_equal [host.name], hosts.map(&:name)
  end

  test "parent_classes should return parent_classes if host has hostgroup and environment are the same" do
    hostgroup        = FactoryGirl.create(:hostgroup, :with_puppetclass)
    host             = FactoryGirl.create(:host, :hostgroup => hostgroup, :environment => hostgroup.environment)
    assert host.hostgroup
    refute_empty host.parent_classes
    assert_equal host.parent_classes, host.hostgroup.classes
  end

  test "parent_classes should not return parent classes that do not match environment" do
    # one class in the right env, one in a different env
    pclass1 = FactoryGirl.create(:puppetclass, :environments => [environments(:testing), environments(:production)])
    pclass2 = FactoryGirl.create(:puppetclass, :environments => [environments(:production)])
    hostgroup        = FactoryGirl.create(:hostgroup, :puppetclasses => [pclass1, pclass2], :environment => environments(:testing))
    host             = FactoryGirl.create(:host, :hostgroup => hostgroup, :environment => environments(:production))
    assert host.hostgroup
    refute_empty host.parent_classes
    refute_equal host.environment, host.hostgroup.environment
    refute_equal host.parent_classes, host.hostgroup.classes
  end

  test "parent_classes should return empty array if host does not have hostgroup" do
    host = FactoryGirl.create(:host)
    assert_nil host.hostgroup
    assert_empty host.parent_classes
  end

  test "parent_config_groups should return parent config_groups if host has hostgroup" do
    hostgroup        = FactoryGirl.create(:hostgroup, :with_config_group)
    host             = FactoryGirl.create(:host, :hostgroup => hostgroup, :environment => hostgroup.environment)
    assert host.hostgroup
    assert_equal host.parent_config_groups, host.hostgroup.config_groups
  end

  test "parent_config_groups should return empty array if host has no hostgroup" do
    host = FactoryGirl.create(:host)
    refute host.hostgroup
    assert_empty host.parent_config_groups
  end

  test "individual puppetclasses added to host (that can be removed) does not include classes that are included by config group" do
    host   = FactoryGirl.create(:host, :with_config_group)
    pclass = FactoryGirl.create(:puppetclass, :environments => [host.environment])
    host.puppetclasses << pclass
    # not sure why, but .classes and .puppetclasses don't return the same thing here...
    assert_equal (host.config_groups.first.classes + [pclass]).map(&:name).sort, host.classes.map(&:name).sort
    assert_equal [pclass.name], host.individual_puppetclasses.map(&:name)
  end

  test "available_puppetclasses should return all if no environment" do
    host = FactoryGirl.create(:host)
    host.update_attribute(:environment_id, nil)
    assert_equal Puppetclass.where(nil), host.available_puppetclasses
  end

  test "available_puppetclasses should return environment-specific classes" do
    host = FactoryGirl.create(:host, :with_environment)
    refute_equal Puppetclass.where(nil), host.available_puppetclasses
    assert_equal host.environment.puppetclasses.sort, host.available_puppetclasses.sort
  end

  test "available_puppetclasses should return environment-specific classes (and that are NOT already inherited by parent)" do
    hostgroup        = FactoryGirl.create(:hostgroup, :with_puppetclass)
    host             = FactoryGirl.create(:host, :hostgroup => hostgroup, :environment => hostgroup.environment)
    refute_equal Puppetclass.where(nil), host.available_puppetclasses
    refute_equal host.environment.puppetclasses.sort, host.available_puppetclasses.sort
    assert_equal (host.environment.puppetclasses - host.parent_classes).sort, host.available_puppetclasses.sort
  end

  test "#info ENC YAML omits root_pw when password_hash is set to Base64" do
    host = FactoryGirl.build(:host, :managed)
    host.hostgroup = nil

    unencrypted_password = "xybxa6JUkz63w"

    host.operatingsystem.password_hash = 'Base64'
    host.root_pass = unencrypted_password
    assert host.save!
    enc = host.info
    assert_kind_of Hash, enc
    assert_nil enc['parameters']['root_pw']

    host.operatingsystem.password_hash = 'SHA512'
    host.root_pass = unencrypted_password
    assert host.save!
    enc = host.info
    assert_kind_of Hash, enc
    refute_nil enc['parameters']['root_pw']
  end

  test "#info ENC YAML uses all_puppetclasses for non-parameterized output" do
    Setting[:Parametrized_Classes_in_ENC] = false
    myclass = mock('myclass')
    myclass.expects(:name).returns('myclass')
    host = FactoryGirl.build(:host, :with_environment)
    host.expects(:all_puppetclasses).returns([myclass])
    enc = host.info
    assert_kind_of Hash, enc
    assert_equal ['myclass'], enc['classes']
  end

  test "#info ENC YAML omits environment if not set" do
    host = FactoryGirl.build(:host)
    host.environment = nil
    enc = host.info
    refute_includes enc.keys, 'environment'
  end

  test '#info ENC YAML contains domain name and description' do
    host = FactoryGirl.build(:host, :domain => FactoryGirl.build(:domain, :name => 'example.tst', :fullname => 'custom text'))
    enc = host.info
    assert_equal 'example.tst', enc['parameters']['domainname']
    assert_equal 'custom text', enc['parameters']['foreman_domain_description']
  end

  test "#info ENC YAML returns no puppet classes if no environment" do
    puppetclass = FactoryGirl.create(:puppetclass)
    host = FactoryGirl.create(:host, :puppetclasses => [puppetclass])

    assert_empty host.info['classes']
  end

  test "#info ENC YAML uses Classification::ClassParam for parameterized output" do
    Setting[:Parametrized_Classes_in_ENC] = true
    Setting[:Enable_Smart_Variables_in_ENC] = true
    host = FactoryGirl.build(:host, :with_environment)
    classes = {'myclass' => {'myparam' => 'myvalue'}}
    classification = mock('Classification::ClassParam')
    classification.expects(:enc).returns(classes)
    Classification::ClassParam.expects(:new).with(:host => host).returns(classification)
    enc = host.info
    assert_kind_of Hash, enc
    assert_equal classes, enc['classes']
  end

  test '#info ENC YAML contains ipv4 and ipv6 subnets' do
    host = FactoryGirl.build(:host, :with_subnet, :with_ipv6_subnet)
    enc = host.info
    assert enc['parameters']['foreman_subnets'].any? {|s| s['network_type'] == 'IPv4'}
    assert enc['parameters']['foreman_subnets'].any? {|s| s['network_type'] == 'IPv6'}
  end

  test "#info ENC YAML contains config_groups" do
    host = FactoryGirl.build(:host)
    host.config_groups = [config_groups(:one)]
    enc = host.info
    assert_includes(enc.keys, 'foreman_config_groups')
    assert_includes(enc['foreman_config_groups'], 'Monitoring')
  end

  test "#info ENC YAML contains parent hostgroup config_groups" do
    host = FactoryGirl.build(:host, :with_hostgroup)
    hostgroup = host.hostgroup
    host.config_groups = [config_groups(:one)]
    hostgroup.config_groups = [config_groups(:two)]
    enc = host.info
    assert_equal(enc['foreman_config_groups'], ['Monitoring', 'Security'])
  end

  describe 'cloning' do
    test 'relationships are copied' do
      host = FactoryGirl.create(:host, :with_config_group, :with_puppetclass, :with_parameter)
      key = FactoryGirl.create(:puppetclass_lookup_key, :as_smart_class_param, :key_type => 'string',
                                :override => true, :puppetclass => host.puppetclasses.first)
      LookupValue.create(:value => 'abc', :match => host.lookup_value_matcher, :lookup_key_id => key.id)
      copy = host.clone
      assert_equal host.host_classes.map(&:puppetclass_id), copy.host_classes.map(&:puppetclass_id)
      assert_equal host.host_parameters.map(&:name), copy.host_parameters.map(&:name)
      assert_equal host.host_parameters.map(&:value), copy.host_parameters.map(&:value)
      assert_equal host.host_config_groups.map(&:config_group_id), copy.host_config_groups.map(&:config_group_id)
      assert_equal host.lookup_values.map(&:key), copy.lookup_values.map(&:key)
      assert_equal host.lookup_values.map(&:value), copy.lookup_values.map(&:value)
    end

    test '#classes etc. on cloned host return the same' do
      hostgroup = FactoryGirl.create(:hostgroup, :with_config_group, :with_puppetclass)
      host = FactoryGirl.create(:host, :with_config_group, :with_puppetclass, :with_parameter, :hostgroup => hostgroup, :environment => hostgroup.environment)
      copy = host.clone
      assert_equal host.individual_puppetclasses.map(&:id), copy.individual_puppetclasses.map(&:id)
      assert_equal host.classes_in_groups.map(&:id), copy.classes_in_groups.map(&:id)
      assert_equal host.classes.map(&:id), copy.classes.map(&:id)
      assert_equal host.available_puppetclasses.map(&:id), copy.available_puppetclasses.map(&:id)
    end

    test 'lookup values are copied' do
      host = FactoryGirl.create(:host, :with_puppetclass)
      FactoryGirl.create(:puppetclass_lookup_key, :as_smart_class_param, :with_override, :puppetclass => host.puppetclasses.first, :overrides => {host.lookup_value_matcher => 'test'})
      copy = host.clone
      assert_equal 1, host.lookup_values.reload.size
      assert_equal 1, copy.lookup_values.size
      assert_equal host.lookup_values.map(&:value), copy.lookup_values.map(&:value)
    end

    test 'clone host should not copy name, system fields (mac, ip, etc)' do
      host = FactoryGirl.create(:host, :with_config_group, :with_puppetclass, :with_parameter, :dualstack)
      copy = host.clone
      assert copy.name.blank?
      assert copy.mac.blank?
      assert copy.ip.blank?
      assert copy.ip6.blank?
      assert copy.uuid.blank?
      assert copy.certname.blank?
      assert copy.last_report.blank?
    end

    test 'clone host should copy interfaces without name, mac and ip' do
      host = FactoryGirl.create(:host, :with_config_group, :with_puppetclass, :with_parameter, :dualstack)
      copy = host.clone

      assert_equal host.interfaces.length, copy.interfaces.length

      interface = copy.interfaces.first
      assert interface.name.blank?
      assert interface.mac.blank?
      assert interface.ip.blank?
      assert interface.ip6.blank?
    end

    test 'without save makes no changes' do
      host = FactoryGirl.create(:host, :with_config_group, :with_puppetclass, :with_parameter)
      FactoryGirl.create(:puppetclass_lookup_key, :as_smart_class_param, :with_override, :puppetclass => host.puppetclasses.first, :overrides => {host.lookup_value_matcher => 'test'})
      ActiveRecord::Base.any_instance.expects(:destroy).never
      ActiveRecord::Base.any_instance.expects(:save).never
      host.clone
    end
  end

  test 'fqdn of host with period in name returns just name with no concatenation of domain' do
    host = FactoryGirl.create(:host, :hostname => 'my5name.mydomain.net')
    assert_equal 'my5name.mydomain.net', host.name
    assert_equal host.name, host.fqdn
  end

  test 'fqdn of host without period in name returns name concatenated with domain' do
    host = Host::Managed.new(:name => 'otherfullhost', :domain => domains(:mydomain))
    assert_equal 'otherfullhost', host.name
    assert_equal 'mydomain.net', host.domain.name
    assert_equal 'otherfullhost.mydomain.net', host.fqdn
  end

  test 'fqdn of host period and no domain returns just name' do
    assert_equal "dhcp123", Host::Managed.new(:name => "dhcp123").fqdn
  end

  test 'clone should create compute_attributes for VM-based hosts' do
    host = FactoryGirl.create(:host, :compute_resource => compute_resources(:ec2))
    ComputeResource.any_instance.stubs(:vm_compute_attributes_for).returns({:foo => 'bar'})
    copy = host.clone
    assert !copy.compute_attributes.nil?
  end

  test 'clone should NOT create compute_attributes for bare-metal host' do
    host = FactoryGirl.create(:host)
    ComputeResource.any_instance.stubs(:vm_compute_attributes_for).returns({:foo => 'bar'})
    copy = host.clone
    assert copy.compute_attributes.nil?
  end

  test 'facts are deleted when build set to true' do
    host = FactoryGirl.create(:host, :with_facts, :managed)
    assert host.fact_values.present?
    refute host.build?
    host.update_attributes(:build => true)
    assert_empty host.fact_values.reload
  end

  test 'reports are deleted when build set to true' do
    host = FactoryGirl.create(:host, :with_reports, :managed)
    assert host.reports.present?
    refute host.build?
    host.update_attributes(:build => true)
    assert_empty host.reports.reload
  end

  test 'host.last_report is deleted when build set to true' do
    host = FactoryGirl.create(:host, :with_reports, :managed)
    refute host.build?
    refute host.last_report.blank?
    host.update_attributes(:build => true)
    assert host.last_report.blank?
  end

  test 'changing name with a fqdn should rename lookup_value matcher' do
    host = FactoryGirl.create(:host)
    lookup_key = FactoryGirl.create(:puppetclass_lookup_key)
    lookup_value = FactoryGirl.create(:lookup_value, :lookup_key_id => lookup_key.id,
                                      :match => "fqdn=#{host.fqdn}", :value => '8080')
    host.reload
    assert_equal "fqdn=#{host.fqdn}", LookupValue.find(lookup_value.id).match

    host.name = "my5name-new.mydomain.net"
    host.save!
    assert_equal "fqdn=my5name-new.mydomain.net", LookupValue.find(lookup_value.id).match
  end

  test 'changing only name should rename lookup_value matcher' do
    host = FactoryGirl.create(:host, :domain => FactoryGirl.create(:domain))
    lookup_key = FactoryGirl.create(:puppetclass_lookup_key)
    lookup_value = FactoryGirl.create(:lookup_value, :lookup_key_id => lookup_key.id,
                                      :match => "fqdn=#{host.fqdn}", :value => '8080')
    host.reload
    assert_equal LookupValue.find(lookup_value.id).match, "fqdn=#{host.fqdn}"

    host.name = "my5name-new"
    host.save!
    assert_equal "fqdn=my5name-new.#{host.domain.name}", LookupValue.find(lookup_value.id).match
  end

  test 'changing host domain should rename lookup_value matcher' do
    host = FactoryGirl.create(:host)
    lookup_key = FactoryGirl.create(:puppetclass_lookup_key)
    lookup_value = FactoryGirl.create(:lookup_value, :lookup_key_id => lookup_key.id,
                                      :match => "fqdn=#{host.fqdn}", :value => '8080')
    host.reload
    assert_equal LookupValue.find(lookup_value.id).match, "fqdn=#{host.fqdn}"

    host.domain = domains(:yourdomain)
    host.save!
    assert_equal "fqdn=#{host.shortname}.yourdomain.net", LookupValue.find(lookup_value.id).match
  end

  test "destroying host should destroy lookup values" do
    host = FactoryGirl.create(:host)
    lookup_key = FactoryGirl.create(:puppetclass_lookup_key)
    lookup_value = FactoryGirl.create(:lookup_value, :lookup_key_id => lookup_key.id,
                                      :match => "fqdn=#{host.fqdn}", :value => '8080')
    host.reload
    host.destroy
    assert LookupValue.where(:id => lookup_value.id).first.blank?
  end

  test '#setup_clone skips new records' do
    assert_nil FactoryGirl.build(:host, :managed).send(:setup_clone)
  end

  test '#setup_clone is public and clones interfaces so delegated attributes are applied to cloned interfaces' do
    host = FactoryGirl.create(:host, :managed)
    original_mac = host.mac
    host.mac = 'AA:AA:AA:AA:AA:AA'
    clone = host.setup_clone
    refute_equal host.object_id, clone.object_id
    assert_equal 'AA:AA:AA:AA:AA:AA', host.mac
    refute_equal host.mac, clone.mac
    assert_equal original_mac, clone.mac
    assert_equal original_mac, clone.provision_interface.mac
  end

  test '#primary_interface works during deletion' do
    host = FactoryGirl.create(:host, :managed)
    iface = host.interfaces.first
    assert iface.delete
    assert_equal iface, host.primary_interface
  end

  test '#primary_interface is never cached for new record' do
    host = FactoryGirl.build(:host, :managed)
    refute_nil host.primary_interface
    host.interfaces = []
    assert_nil host.primary_interface
  end

  test '#provision_interface is never cached for new record' do
    host = FactoryGirl.build(:host, :managed)
    refute_nil host.provision_interface
    host.interfaces = []
    assert_nil host.provision_interface
  end

  test '#drop_primary_interface_cache' do
    host = FactoryGirl.create(:host, :managed)
    refute_nil host.primary_interface
    host.interfaces.clear
    # existing host must cache interface
    refute_nil host.primary_interface
    host.drop_primary_interface_cache
    assert_nil host.primary_interface
  end

  test '#drop_provision_interface_cache' do
    host = FactoryGirl.create(:host, :managed)
    refute_nil host.provision_interface
    host.interfaces.clear
    # existing host must cache interface
    refute_nil host.provision_interface
    host.drop_provision_interface_cache
    assert_nil host.provision_interface
  end

  test '#reload drops primary and provision interface cache' do
    host = FactoryGirl.create(:host, :managed)
    refute_nil host.primary_interface
    refute_nil host.provision_interface
    host.expects(:drop_primary_interface_cache).once
    host.expects(:drop_provision_interface_cache).once

    host.reload
  end

  test '#becomes drops interface cache on new instance and copies all interfaces' do
    host = FactoryGirl.create(:host, :managed)
    refute_nil host.primary_interface
    refute_nil host.provision_interface
    primary = host.primary_interface

    nic = FactoryGirl.build(:nic_managed, :host => host, :mac => '00:00:00:AA:BB:CC', :ip => '192.168.0.1',
                            :name => 'host2', :domain => host.domain)
    nic.primary = true
    nic.provision = true

    # make cache wrong - I don't find a way how to do it cleanly (which is good)
    host.instance_variable_set '@primary_interface', nic
    host.instance_variable_set '@provision_interface', nic

    converted = host.becomes(Host::Managed)
    assert_equal 1, converted.interfaces.size
    assert_equal primary, converted.interfaces.first
    refute_equal host.primary_interface, converted.primary_interface
    refute_equal host.provision_interface, converted.provision_interface
  end

  test '#initialize builds primary and provision interface if not present in arguments' do
    h = Host.new
    refute_nil h.primary_interface
    refute_nil h.provision_interface
  end

  test '#initialize respects primary interface attributes and sets provision to the same if missing' do
    h = Host.new(:interfaces_attributes => {
                   '0' => {'_destroy' => '0',
                           :type => 'Nic::Managed',
                           :mac => 'ff:ff:ff:aa:aa:aa',
                           :managed => '1',
                           :primary => '1',
                           :provision => '0',
                           :virtual => '0'}
                 })
    refute_nil h.primary_interface
    refute_nil h.provision_interface
    assert_equal 'ff:ff:ff:aa:aa:aa', h.primary_interface.mac
    assert_equal h.primary_interface, h.provision_interface
  end

  test '#initialize respects primary and provision interface attributes' do
    h = Host.new(:interfaces_attributes => {
                   '0' => {'_destroy' => '0',
                           :type => 'Nic::Managed',
                           :mac => 'ff:ff:ff:aa:aa:aa',
                           :managed => '1',
                           :primary => '1',
                           :provision => '0',
                           :virtual => '0'},
              '1' => {'_destroy' => '0',
                      :type => 'Nic::Managed',
                      :mac => 'aa:aa:aa:ff:ff:ff',
                      :managed => '1',
                      :primary => '0',
                      :provision => '1',
                      :virtual => '0'}
                 })
    refute_nil h.primary_interface
    refute_nil h.provision_interface
    assert_equal 'ff:ff:ff:aa:aa:aa', h.primary_interface.mac
    assert_equal 'aa:aa:aa:ff:ff:ff', h.provision_interface.mac
    refute_equal h.primary_interface, h.provision_interface
  end

  describe '#overwrite=' do
    context 'false' do
      [:false, 'false', false].each do |v|
        test "when setting to #{v.inspect}" do
          refute FactoryGirl.build(:host, :overwrite => v).overwrite?
        end
      end
    end

    context 'true' do
      [:true, 'true', true].each do |v|
        test "when setting to #{v.inspect}" do
          assert FactoryGirl.build(:host, :overwrite => v).overwrite?
        end
      end
    end
  end

  test 'updating host domain should validate domain exists' do
    host = FactoryGirl.create(:host, :managed)
    last_domain_id = Domain.order(:id).last.id
    fake_domain_id = last_domain_id + 1
    host.domain_id = fake_domain_id
    refute(host.valid?)
    host.domain_id = last_domain_id
    assert(host.valid?)
  end

  test '#jumpstart? should return true for Solaris and SPARC hosts' do
    host = FactoryGirl.create(:host,
                              :operatingsystem => FactoryGirl.create(:solaris),
                              :architecture => FactoryGirl.create(:architecture, :name => 'SPARC-T2'))
    assert host.jumpstart?
  end

  test '#fqdn returns the FQDN from the primary interface' do
    primary = FactoryGirl.build(:nic_managed, :primary => true, :name => 'foo', :domain => FactoryGirl.build(:domain))
    host = FactoryGirl.create(:host, :managed, :interfaces => [primary, FactoryGirl.build(:nic_managed, :provision => true)])
    assert_equal "foo.#{primary.domain.name}", host.fqdn
  end

  test '#shortname returns the name from the primary interface' do
    primary = FactoryGirl.build(:nic_managed, :primary => true, :name => 'foo')
    host = FactoryGirl.create(:host, :managed, :interfaces => [primary, FactoryGirl.build(:nic_managed, :provision => true)])
    assert_equal 'foo', host.shortname
  end

  test 'lookup_value_match returns host name instead of fqdn when there is no primary interface' do
    host = FactoryGirl.build(:host, :managed)
    host_name = host.name
    host.interfaces.delete_all
    assert_nil host.primary_interface
    assert_equal host.send(:lookup_value_match), "fqdn=#{host_name}"
  end

  test 'check operatingsystem and architecture association' do
    host = FactoryGirl.build(:host, :interfaces => [FactoryGirl.build(:nic_primary_and_provision)])
    assert_nil Operatingsystem.find_by_name('RedHat-test'), "operatingsystem already exist"
    host.populate_fields_from_facts(:architecture => "x86_64", :operatingsystem => 'RedHat-test', :operatingsystemrelease => '6.2')
    assert host.operatingsystem.architectures.include?(host.architecture), "no association between operatingsystem and architecture"
  end

  context "lookup value attributes" do
    test "invoking lookup_values_attributes= does not save lookup values in db until #save is invoked" do
      host = FactoryGirl.create(:host)
      assert_no_difference('LookupValue.count') do
        host.lookup_values_attributes = {"new_123456" => {"lookup_key_id" => lookup_keys(:complex).id, "value"=>"some_value", "match" => "fqdn=abc.mydomain.net"}}
      end

      assert_difference('LookupValue.count') do
        host.save
      end
    end

    test "lookup_values_attributes= updates existing lookup values" do
      host = FactoryGirl.create(:host, :with_puppetclass)
      lkey = FactoryGirl.create(:puppetclass_lookup_key, :as_smart_class_param, :puppetclass => host.classes.first, :overrides => {"fqdn=#{host.name}" => 'old value'})
      lval = host.lookup_values.first

      host.lookup_values_attributes = {'0' => {'lookup_key_id' => lkey.id.to_s, 'value' => 'new value', '_destroy' => '0', 'id' => lval.id.to_s}}.with_indifferent_access
      assert_equal 'old value', LookupValue.find(lval.id).value

      host.save!
      assert_equal 'new value', LookupValue.find(lval.id).value
    end

    test "same works for destruction of lookup keys" do
      host = FactoryGirl.create(:host, :lookup_values_attributes => {"new_123456" => {"lookup_key_id" => lookup_keys(:complex).id, "value"=>"some_value", "match" => "fqdn=abc.mydomain.net"}})
      lookup_value = host.lookup_values.first
      assert_no_difference('LookupValue.count') do
        host.lookup_values_attributes = {'0' => {'lookup_key_id' => lookup_keys(:complex).id.to_s, 'id' => lookup_value.id.to_s, '_destroy' => '1'}}.with_indifferent_access
      end

      assert_difference('LookupValue.count', -1) do
        host.save
      end
    end
  end

  describe '#apply_inherited_attributes' do
    test 'should be no-op if no hostgroup selected' do
      host = FactoryGirl.build(:host, :managed)
      attributes = { 'environment_id' => 1 }

      actual_attr = host.apply_inherited_attributes(attributes)

      assert_equal actual_attr, attributes
    end

    test 'should take new hostgroup if hostgroup_id present' do
      host = FactoryGirl.build(:host, :managed, :with_hostgroup)
      new_environment = FactoryGirl.create(:environment)
      new_hostgroup = FactoryGirl.create(:hostgroup, :environment => new_environment)
      assert_not_equal new_environment.id, host.hostgroup.environment.try(:id)

      attributes = { 'hostgroup_id' => new_hostgroup.id }
      actual_attr = host.apply_inherited_attributes(attributes)

      assert_equal actual_attr['environment_id'], new_environment.id
    end

    test 'should take new hostgroup if hostgroup_name present' do
      host = FactoryGirl.build(:host, :managed, :with_hostgroup)
      new_environment = FactoryGirl.create(:environment)
      new_hostgroup = FactoryGirl.create(:hostgroup, :environment => new_environment)
      assert_not_equal new_environment.id, host.hostgroup.environment.try(:id)

      attributes = { 'hostgroup_name' => new_hostgroup.title }
      actual_attr = host.apply_inherited_attributes(attributes)

      assert_equal actual_attr['environment_id'], new_environment.id
    end

    test 'should take old hostgroup if hostgroup not updated' do
      environment = FactoryGirl.create(:environment)
      host = FactoryGirl.build(:host, :managed, :with_hostgroup, :environment => environment)
      Hostgroup.expects(:find).never

      attributes = { 'hostgroup_id' => host.hostgroup.id }
      actual_attr = host.apply_inherited_attributes(attributes)

      assert_equal actual_attr['environment_id'], host.hostgroup.environment.id
    end

    test 'should accept non-existing hostgroup' do
      host = FactoryGirl.build(:host, :managed, :with_hostgroup)
      hostgroup_friendly_scope = stub
      hostgroup_friendly_scope.stubs(:find).with(1111).returns(nil)
      Hostgroup.stubs(:friendly).returns(hostgroup_friendly_scope)

      attributes = { 'hostgroup_id' => 1111 }
      actual_attr = host.apply_inherited_attributes(attributes)

      assert_nil actual_attr['environment_id']
    end

    test 'should not touch attribute set explicitly' do
      host = FactoryGirl.build(:host, :managed, :with_hostgroup)

      attributes = { 'hostgroup_id' => host.hostgroup.id, 'environment_id' => 1111 }
      actual_attr = host.apply_inherited_attributes(attributes)

      assert_equal actual_attr['environment_id'], 1111
    end

    test 'should inherit attribute value, if not set explicitly' do
      host = FactoryGirl.build(:host, :managed, :with_hostgroup)
      environment = FactoryGirl.create(:environment)
      host.hostgroup.environment = environment
      host.hostgroup.save!

      attributes = { 'hostgroup_id' => host.hostgroup.id }
      actual_attr = host.apply_inherited_attributes(attributes)

      assert_equal actual_attr['environment_id'], host.hostgroup.environment.id
    end

    test 'should not touch non-inherited attributes' do
      host = FactoryGirl.build(:host, :managed, :with_hostgroup)

      attributes = { 'hostgroup_id' => host.hostgroup.id, 'zzz_id' => 1111 }
      actual_attr = host.apply_inherited_attributes(attributes)

      assert_equal actual_attr['zzz_id'], 1111
    end

    test 'should add inherited attributes when hostgroup in attributes' do
      hg = FactoryGirl.create(:hostgroup, :with_environment)
      host = Host.new(:name => "test-host", :hostgroup => hg)
      assert host.environment
    end
  end

  describe 'rendering interface' do
    let(:host) { FactoryGirl.build(:host, :managed) }

    test "#multiboot" do
      host.respond_to?(:multiboot)
    end

    test "#jumpstart_path" do
      host.respond_to?(:jumpstart_path)
    end

    test "#install_path" do
      host.respond_to?(:install_path)
    end

    test "#miniroot" do
      host.respond_to?(:miniroot)
    end
  end

  describe 'interface identifiers validation' do
    let(:host) { FactoryGirl.build(:host, :managed) }
    let(:additional_interface) { host.interfaces.build }

    context 'additional interface has different identifier' do
      test 'host is valid' do
        assert host.valid?
      end
    end

    context 'additional interface has same identifier' do
      before { additional_interface.identifier = host.primary_interface.identifier }

      test 'host is valid' do
        refute host.valid?
      end

      test 'validation ignores interfaces marked for destruction' do
        additional_interface.mark_for_destruction
        assert host.valid?
      end
    end
  end

  context "recreating host config" do
    setup do
      @nic = FactoryGirl.build(:nic_primary_and_provision)
      @nic.expects(:rebuild_tftp).returns(true)
      @nic.expects(:rebuild_dns).returns(true)
      @nic.expects(:rebuild_dhcp).returns(true)
      Nic::Managed.expects(:rebuild_methods).returns(:rebuild_dhcp => "DHCP", :rebuild_dns => "DNS", :rebuild_tftp => "TFTP")
    end

    test "recreate config with success" do
      Host::Managed.expects(:rebuild_methods).returns(:rebuild_test => "TEST")
      host = FactoryGirl.build(:host, :interfaces => [@nic])
      host.expects(:rebuild_test).returns(true)
      result = host.recreate_config
      assert result["DHCP"]
      assert result["DNS"]
      assert result["TFTP"]
      assert result["TEST"]
    end

    test "recreate config with clashing methods" do
      Host::Managed.expects(:rebuild_methods).returns(:rebuild_dns => "DNS")
      host = FactoryGirl.build(:host, :interfaces => [@nic])
      assert_raises(Foreman::Exception) { host.recreate_config }
    end

    context "recreate with multiple nics and failures" do
      setup do
        @nic2 = FactoryGirl.build(:nic_managed)
        @nic2.expects(:rebuild_tftp).returns(false)
        @nic2.expects(:rebuild_dns).returns(false)
        @nic2.expects(:rebuild_dhcp).returns(false)
      end

      test "second is a failure" do
        host = FactoryGirl.build(:host, :interfaces => [@nic, @nic2])
        result = host.recreate_config
        refute result["DHCP"]
        refute result["DNS"]
        refute result["TFTP"]
      end

      test "first is a failure" do
        host = FactoryGirl.build(:host, :interfaces => [@nic2, @nic])
        result = host.recreate_config
        refute result["DHCP"]
        refute result["DNS"]
        refute result["TFTP"]
      end
    end

    test "recreate with multiple nics, all are success" do
      nic = FactoryGirl.build(:nic_managed)
      nic.expects(:rebuild_tftp).returns(true)
      nic.expects(:rebuild_dns).returns(true)
      nic.expects(:rebuild_dhcp).returns(true)
      host = FactoryGirl.build(:host, :interfaces => [@nic, nic])
      result = host.recreate_config
      assert result["DHCP"]
      assert result["DNS"]
      assert result["TFTP"]
    end
  end

  test 'should display inherited parameters' do
    host = FactoryGirl.create(:host,
                              :location => taxonomies(:location1),
                              :organization => taxonomies(:organization1),
                              :domain => domains(:mydomain))
    location_parameter = LocationParameter.new(:name => 'location', :value => 'parameter')
    host.location.location_parameters = [location_parameter]
    assert(host.host_inherited_params_objects.include?(location_parameter), 'Taxonomy parameters should be included')
  end

  test '#host_params_objects should display all parameters with overrides' do
    host = FactoryGirl.create(:host,
                              :location => taxonomies(:location1),
                              :organization => taxonomies(:organization1),
                              :domain => domains(:mydomain))
    location_parameter = LocationParameter.new(:name => 'location', :value => 'parameter')
    host.location.location_parameters = [location_parameter]
    host_location_override = HostParameter.new(:name => 'location', :value => 'the moon')
    host.host_parameters += [host_location_override]
    assert(host.host_params_objects.include?(host_location_override), 'Location parameter should be overriden')
    refute(host.host_params_objects.include?(location_parameter), 'Location parameter should not be included')
  end

  test 'host_params_objects should display parameters in the right order' do
    host = FactoryGirl.create(:host,
                              :location => taxonomies(:location1),
                              :organization => taxonomies(:organization1),
                              :domain => domains(:mydomain))
    domain_parameter = DomainParameter.new(:name => 'domain', :value => 'here.there')
    host.domain.domain_parameters = [domain_parameter]
    assert_equal(domain_parameter, host.host_params_objects.first, 'with no hostgroup, DomainParameter should be first parameter')
    assert(host.host_params_objects.last.is_a?(CommonParameter), 'CommonParameter should be last parameter')
  end

  describe '#param_true?' do
    test 'returns false for unknown parameter' do
      Foreman::Cast.expects(:to_bool).never
      refute FactoryGirl.build(:host).param_true?('unknown')
    end

    test 'returns false for parameter with false-like value' do
      Foreman::Cast.expects(:to_bool).with('0').returns(false)
      host = FactoryGirl.create(:host)
      FactoryGirl.create(:host_parameter, :host => host, :name => 'host_param', :value => '0')
      refute host.reload.param_true?('host_param')
    end

    test 'returns true for parameter with true-like value' do
      Foreman::Cast.expects(:to_bool).with('1').returns(true)
      host = FactoryGirl.create(:host)
      FactoryGirl.create(:host_parameter, :host => host, :name => 'host_param', :value => '1')
      assert host.reload.param_true?('host_param')
    end

    test 'uses inherited parameters' do
      Foreman::Cast.expects(:to_bool).with('1').returns(true)
      host = FactoryGirl.create(:host, :with_hostgroup)
      FactoryGirl.create(:hostgroup_parameter, :hostgroup => host.hostgroup, :name => 'group_param', :value => '1')
      assert host.reload.param_true?('group_param')
    end
  end

  describe '#param_false?' do
    test 'returns false for unknown parameter' do
      Foreman::Cast.expects(:to_bool).never
      refute FactoryGirl.build(:host).param_false?('unknown')
    end

    test 'returns true for parameter with false-like value' do
      Foreman::Cast.expects(:to_bool).with('0').returns(false)
      host = FactoryGirl.create(:host)
      FactoryGirl.create(:host_parameter, :host => host, :name => 'host_param', :value => '0')
      assert host.reload.param_false?('host_param')
    end

    test 'returns false for parameter with true-like value' do
      Foreman::Cast.expects(:to_bool).with('1').returns(true)
      host = FactoryGirl.create(:host)
      FactoryGirl.create(:host_parameter, :host => host, :name => 'host_param', :value => '1')
      refute host.reload.param_false?('host_param')
    end

    test 'uses inherited parameters' do
      Foreman::Cast.expects(:to_bool).with('0').returns(false)
      host = FactoryGirl.create(:host, :with_hostgroup)
      FactoryGirl.create(:hostgroup_parameter, :hostgroup => host.hostgroup, :name => 'group_param', :value => '0')
      assert host.reload.param_false?('group_param')
    end
  end

  context 'compute resources' do
    setup do
      @group1 = FactoryGirl.create(:hostgroup, :with_domain, :with_os, :compute_profile => compute_profiles(:one))
      @group2 = FactoryGirl.create(:hostgroup, :with_domain, :with_os, :compute_profile => compute_profiles(:two))
    end

    test 'set_hostgroup_defaults doesnt touch compute attributes' do
      host = FactoryGirl.create(:host, :managed, :compute_resource => compute_resources(:one), :hostgroup => @group1)
      assert_not_equal 4, host.compute_attributes['cpus']

      host.attributes = host.apply_inherited_attributes('hostgroup_id' => @group2.id)
      host.set_hostgroup_defaults
      assert_not_equal 4, host.compute_attributes['cpus']
    end

    test 'set_compute_attributes changes the compute attributes' do
      host = FactoryGirl.create(:host, :managed, :compute_resource => compute_resources(:one), :hostgroup => @group1)
      assert_not_equal 4, host.compute_attributes['cpus']

      host.attributes = host.apply_inherited_attributes('hostgroup_id' => @group2.id)
      host.set_compute_attributes
      assert_equal 4, host.compute_attributes['cpus']
    end
  end

  describe '.for_vm' do
    test 'returns hosts with matching CR and identity' do
      uuid = Foreman.uuid
      vm = mock('vm', :identity => uuid)
      host = FactoryGirl.create(:host, :on_compute_resource, :uuid => uuid)
      assert_equal [host], Host::Managed.for_vm(host.compute_resource, vm).to_a
    end

    test 'returns hosts with matching an integer identity' do
      vm = mock('vm', :identity => 42)
      host = FactoryGirl.create(:host, :on_compute_resource, :uuid => '42')
      assert_equal [host], Host::Managed.for_vm(host.compute_resource, vm).to_a
    end
  end

  test 'hardware_model_name= sets model_id by name' do
    model = FactoryGirl.create(:model)
    host = FactoryGirl.build(:host)
    Foreman::Deprecation.expects(:deprecation_warning).never
    host.hardware_model_name = model.name
    assert_equal model.id, host.model_id
  end

  test '.new handles model_name without deprecation warning' do
    model = FactoryGirl.create(:model)
    Foreman::Deprecation.expects(:deprecation_warning).never
    assert_equal model.id, Host::Managed.new(:model_name => model.name).model_id
  end

  test 'hardware_model_id= is aliased to model_id' do
    host = FactoryGirl.build(:host)
    Foreman::Deprecation.expects(:deprecation_warning).never
    host.hardware_model_id = 42
    assert_equal 42, host.model_id
    assert_equal 42, host.hardware_model_id
  end

  describe "loading compute_attributes from compute profile" do
    setup do
      @compute_attrs = compute_attributes(:one)

      @host = FactoryGirl.build(:host)
      @host.compute_attributes = {}
      @host.compute_resource = @compute_attrs.compute_resource
      @host.compute_profile = @compute_attrs.compute_profile
    end

    test "should create host with compute profile when compute_attributes are empty" do
      @host.compute_resource.expects(:create_vm).once.with do |vm_attrs|
        vm_attrs['flavor_id'] == @compute_attrs.vm_attrs['flavor_id'] &&
        vm_attrs['availability_zone'] == @compute_attrs.vm_attrs['availability_zone']
      end

      @host.valid?
      @host.send(:setCompute)
    end

    test "should create host with compute profile when compute_attributes are nil" do
      @host.compute_attributes = nil
      @host.compute_resource.expects(:create_vm).once.with do |vm_attrs|
        vm_attrs['flavor_id'] == @compute_attrs.vm_attrs['flavor_id'] &&
        vm_attrs['availability_zone'] == @compute_attrs.vm_attrs['availability_zone']
      end

      @host.valid?
      @host.send(:setCompute)
    end

    test "should create host without compute profile when compute_attributes contain some data" do
      @host.compute_attributes = {
        "volumes_attributes"=>{
          '0' => {
            'size' => 20
          }
        },
        "interfaces_attributes"=>{},
        "nics_attributes"=>{}
      }

      @host.compute_resource.expects(:create_vm).once.with do |vm_attrs|
        (vm_attrs['volumes_attributes']['0']['size'] == 20) &&
        vm_attrs['flavor_id'].nil? &&
        vm_attrs['availability_zone'].nil?
      end

      @host.valid?
      @host.send(:setCompute)
    end
  end

  describe 'apply_compute_profile' do
    test 'modificator gets correct paramaters' do
      host = FactoryGirl.build(:host, :on_compute_resource, :with_compute_profile)

      modificator = stub
      modificator.expects(:run).with do |_host, attrs|
        (attrs.compute_resource == host.compute_resource) &&
        (attrs.compute_profile == host.compute_profile)
      end

      host.apply_compute_profile(modificator)
    end

    test 'modificator gets nil when the compute_resource does not exist' do
      host = FactoryGirl.build(:host)

      modificator = stub
      modificator.expects(:run).with(host, nil)

      host.apply_compute_profile(modificator)
    end

    test 'modificator gets nil when the compute_profile does not exist' do
      host = FactoryGirl.build(:host, :on_compute_resource)

      modificator = stub
      modificator.expects(:run).with(host, nil)

      host.apply_compute_profile(modificator)
    end
  end

  describe 'taxonomy scopes' do
    test 'no_location overrides default scope' do
      location = FactoryGirl.create(:location)
      host = FactoryGirl.create(:host, :location => nil)
      Location.stubs(:current).returns(location)

      assert_nil Host.where(:id => host.id).first
      assert_not_nil Host.no_location.where(:id => host.id).first
      Location.unstub(:current)
    end

    test 'no_organization overrides default scope' do
      organization = FactoryGirl.create(:organization)
      host = FactoryGirl.create(:host, :organization => nil)
      Organization.stubs(:current).returns(organization)

      assert_nil Host.where(:id => host.id).first
      assert_not_nil Host.no_organization.where(:id => host.id).first
      Organization.unstub(:current)
    end
  end

  describe '#to_ip_address' do
    setup do
      @host = FactoryGirl.build(:host)
    end

    test 'uses host PTR4 record to lookup the IP when present' do
      stub_dns_record = stub()
      @host.expects(:dns_record).with(:ptr4).returns(stub_dns_record).twice
      stub_dns_record.expects(:dns_lookup).with('foo').
        returns(OpenStruct.new(:ip => '127.0.0.1'))
      assert '127.0.0.1', @host.to_ip_address('foo')
    end

    test 'when IP is passed as argument, return it' do
      assert '127.0.0.1', @host.to_ip_address('127.0.0.1')
    end

    test 'call host domain resolver if there is no PTR4 record' do
      @host.domain = FactoryGirl.build(:domain)
      @host.domain.expects(:nameservers).returns('8.8.8.8')
      Resolv::DNS.any_instance.expects(:getaddress).with('foo')
        .returns('127.0.0.1')
      assert '127.0.0.1', @host.to_ip_address('foo')
    end

    test 'raises exception when any error happens (no domain)' do
      assert_raises(::Foreman::WrappedException) do
        @host.to_ip_address('foo')
      end
    end
  end

  describe '#smart_proxy_ids' do
    test 'returns IDs for proxies associated with host services' do
      # IDs are fake, just to prove host.smart_proxy_ids gathers them
      host = FactoryGirl.build(:host, :with_subnet, :with_realm,
                               :puppet_proxy_id => 1,
                               :puppet_ca_proxy_id => 1)
      host.realm = FactoryGirl.build(:realm, :realm_proxy_id => 1)
      host.subnet.tftp_id = 2
      host.subnet.dhcp_id = 3
      host.subnet.dns_id = 4
      assert host.smart_proxy_ids, [1,2,3,4]
    end

    context 'from hostgroup' do
      setup do
        @hostgroup = FactoryGirl.create(:hostgroup, :with_puppet_orchestration)
        @host = FactoryGirl.build(:host)
        @host.hostgroup = @hostgroup
        @host.send(:assign_hostgroup_attributes,
                   [:puppet_ca_proxy_id, :puppet_proxy_id])
      end

      test 'returns IDs for proxies used by services inherited from hostgroup' do
        @host.realm = FactoryGirl.build(:realm, :realm_proxy_id => 1)
        assert_equal [@hostgroup.puppet_ca_proxy_id,
                      @hostgroup.puppet_proxy_id,
                      @host.realm.realm_proxy_id].sort,
                      @host.smart_proxy_ids.sort
      end

      test 'does not return IDs for services not inherited from the hostgroup' do
        @host.realm = FactoryGirl.build(:realm, :realm_proxy_id => 1)
        @host.puppet_proxy_id = nil
        assert_equal [@hostgroup.puppet_ca_proxy_id,
                      @host.realm.realm_proxy_id].sort,
                      @host.smart_proxy_ids.sort
      end
    end
  end

  private

  def setup_host_with_nic_parser(nic_attributes)
    host = FactoryGirl.create(:host, :hostgroup => FactoryGirl.create(:hostgroup))
    hash = { (nic_attributes.delete(:identifier) || :eth0) => nic_attributes
    }.with_indifferent_access
    parser = stub(:interfaces => hash, :ipmi_interface => {}, :suggested_primary_interface => hash.to_a.first)
    [host, parser]
  end

  def setup_host_with_ipmi_parser(ipmi_attributes)
    host = FactoryGirl.create(:host, :hostgroup => FactoryGirl.create(:hostgroup))
    hash = ipmi_attributes.with_indifferent_access
    primary = host.primary_interface
    parser = stub(:ipmi_interface => hash, :interfaces => {}, :suggested_primary_interface => [ primary.identifier, {:macaddress => primary.mac, :ipaddress => primary.ip} ])
    [host, parser]
  end
end
