require 'test_helper'

class UsergroupTest < ActiveSupport::TestCase
  setup do
    User.current = users :admin
  end

  test "usergroups should be creatable" do
    assert FactoryGirl.build(:usergroup).valid?
  end

  test "name is unique across user as well as usergroup" do
    User.expects(:where).with(:login => 'usergroup1').returns(['fakeuser'])
    usergroup = FactoryGirl.build(:usergroup, :name => 'usergroup1')
    refute usergroup.valid?
  end

  should validate_uniqueness_of(:name)
  should validate_presence_of(:name)
  should have_many(:usergroup_members).dependent(:destroy)
  should have_many(:users).dependent(:destroy)

  def populate_usergroups
    (1..6).each do |number|
      instance_variable_set("@ug#{number}", FactoryGirl.create(:usergroup, :name=> "ug#{number}"))
      instance_variable_set("@u#{number}", FactoryGirl.create(:user, :mail => "u#{number}@someware.com",
                                                              :login => "u#{number}"))
    end

    @ug1.users      = [@u1, @u2]
    @ug2.users      = [@u2, @u3]
    @ug3.users      = [@u3, @u4]
    @ug3.usergroups = [@ug1]
    @ug4.usergroups = [@ug1, @ug2]
    @ug5.usergroups = [@ug1, @ug3, @ug4]
    @ug5.users      = [@u5]
  end

  test "hosts should be retrieved from recursive/complex usergroup definitions" do
    populate_usergroups
    disable_orchestration

    @h1 = FactoryGirl.create(:host, :owner => @u1)
    @h2 = FactoryGirl.create(:host, :owner => @ug2)
    @h3 = FactoryGirl.create(:host, :owner => @u3)
    @h4 = FactoryGirl.create(:host, :owner => @ug5)
    @h5 = FactoryGirl.create(:host, :owner => @u2)
    @h6 = FactoryGirl.create(:host, :owner => @ug3)

    assert_equal @u1.hosts.sort, [@h1]
    assert_equal @u2.hosts.sort, [@h2, @h5]
    assert_equal @u3.hosts.sort, [@h2, @h3, @h6]
    assert_equal @u4.hosts.sort, [@h6]
    assert_equal @u5.hosts.sort, [@h2, @h4, @h6]
    assert_equal @u6.hosts.sort, []
  end

  test "addresses should be retrieved from recursive/complex usergroup definitions" do
    populate_usergroups

    assert_equal @ug1.recipients.sort, %w{u1@someware.com u2@someware.com}
    assert_equal @ug2.recipients.sort, %w{u2@someware.com u3@someware.com}
    assert_equal @ug3.recipients.sort, %w{u1@someware.com u2@someware.com u3@someware.com u4@someware.com}
    assert_equal @ug4.recipients.sort, %w{u1@someware.com u2@someware.com u3@someware.com}
    assert_equal @ug5.recipients.sort, %w{u1@someware.com u2@someware.com u3@someware.com u4@someware.com u5@someware.com}
  end

  test "cannot be destroyed when in use by a host" do
    disable_orchestration
    @ug1 = Usergroup.where(:name => "ug1").first_or_create
    @h1  = FactoryGirl.create(:host)
    @h1.update_attributes :owner => @ug1
    @ug1.destroy
    assert_equal @ug1.errors.full_messages[0], "ug1 is used by #{@h1}"
  end

  test "can be destroyed when in use by another usergroup, it removes association automatically" do
    @ug1 = Usergroup.where(:name => "ug1").first_or_create
    @ug2 = Usergroup.where(:name => "ug2").first_or_create
    @ug1.usergroups = [@ug2]
    assert @ug1.destroy
    assert @ug2.reload
    assert_empty UsergroupMember.where(:member_id => @ug2.id)
  end

  test "removes all cached_user_roles when roles are disassociated" do
    user         = FactoryGirl.create(:user)
    record       = FactoryGirl.create(:usergroup)
    record.users = [user]
    one          = FactoryGirl.create(:role)
    two          = FactoryGirl.create(:role)

    record.roles = [one, two]
    assert_equal 3, user.reload.cached_user_roles.size

    assert record.update_attributes(:role_ids => [ two.id ])
    assert_equal 2, user.reload.cached_user_roles.size

    record.role_ids = [ ]
    assert_equal 1, user.reload.cached_user_roles.size

    assert record.update_attribute(:role_ids, [ one.id ])
    assert_equal 2, user.reload.cached_user_roles.size

    record.roles << two
    assert_equal 3, user.reload.cached_user_roles.size
  end

  test 'add_users is case insensitive and does not add nonexistent users' do
    usergroup = FactoryGirl.create(:usergroup)
    usergroup.send(:add_users, ['OnE', 'TwO', 'tHREE'])

    # users 'one' 'two' are defined in fixtures, 'three' is not defined
    assert_equal ['one', 'two'], usergroup.users.map(&:login).sort
  end

  test 'remove_users removes user list and is case insensitive' do
    usergroup = FactoryGirl.create(:usergroup)
    usergroup.send(:add_users, ['OnE', 'tWo'])
    assert_equal ['one', 'two'], usergroup.users.map(&:login).sort

    usergroup.send(:remove_users, ['ONE', 'TWO'])
    assert_equal [], usergroup.users
  end

  test "can remove the admin flag from the group when another admin exists" do
    usergroup = FactoryGirl.create(:usergroup, :admin => true)
    admin1 = FactoryGirl.create(:user)
    admin2 = FactoryGirl.create(:user, :admin => true)
    usergroup.users = [admin1]

    User.unscoped.except_hidden.only_admin.where('login NOT IN (?)', [admin1.login, admin2.login]).destroy_all
    usergroup.admin = false
    assert_valid usergroup
  end

  test "cannot remove the admin flag from the group providing the last admin account(s)" do
    usergroup = FactoryGirl.create(:usergroup, :admin => true)
    admin = FactoryGirl.create(:user)
    usergroup.users = [admin]

    User.unscoped.except_hidden.only_admin.where('login <> ?', admin.login).destroy_all
    usergroup.admin = false
    refute_valid usergroup, :admin, /last admin account/
  end

  test "cannot destroy the group providing the last admin accounts" do
    usergroup = FactoryGirl.create(:usergroup, :admin => true)
    admin = FactoryGirl.create(:user)
    usergroup.users = [admin]

    User.unscoped.except_hidden.only_admin.where('login <> ?', admin.login).destroy_all
    refute_with_errors usergroup.destroy, usergroup, :base, /last admin user group/
  end

  test "receipients_for provides subscribers of notification recipients" do
    users = [FactoryGirl.create(:user, :with_mail_notification), FactoryGirl.create(:user)]
    notification = users[0].mail_notifications.first.name
    usergroup = FactoryGirl.create(:usergroup)
    usergroup.users << users
    recipients = usergroup.recipients_for(notification)
    assert_equal recipients, [users[0]]
  end

  # TODO test who can modify usergroup roles and who can assign users!!! possible privileges escalation

  context 'external usergroups' do
    setup do
      @usergroup = FactoryGirl.create(:usergroup)
      @external = @usergroup.external_usergroups.new(:auth_source_id => FactoryGirl.create(:auth_source_ldap).id,
                                                     :name           => 'aname')
      LdapFluff.any_instance.stubs(:ldap).returns(Net::LDAP.new)
    end

    test "can be associated with external_usergroups" do
      LdapFluff.any_instance.stubs(:valid_group?).returns(true)

      assert @external.save
      assert @usergroup.external_usergroups.include? @external
    end

    test "won't save if usergroup is not in LDAP" do
      LdapFluff.any_instance.stubs(:valid_group?).returns(false)

      refute @external.save
      assert_equal @external.errors.first, [:name, 'is not found in the authentication source']
    end

    test "delete user if not in LDAP directory" do
      LdapFluff.any_instance.stubs(:valid_group?).with('aname').returns(false)
      @usergroup.users << users(:one)
      @usergroup.save

      AuthSourceLdap.any_instance.expects(:users_in_group).with('aname').returns([])
      @usergroup.external_usergroups.find { |eu| eu.name == 'aname'}.refresh

      refute_includes @usergroup.users, users(:one)
    end

    test "add user if in LDAP directory" do
      LdapFluff.any_instance.stubs(:valid_group?).with('aname').returns(true)
      @usergroup.save

      AuthSourceLdap.any_instance.expects(:users_in_group).with('aname').returns([users(:one).login])
      @usergroup.external_usergroups.find { |eu| eu.name == 'aname'}.refresh
      assert_includes @usergroup.users, users(:one)
    end

    test "keep user if in LDAP directory" do
      LdapFluff.any_instance.stubs(:valid_group?).with('aname').returns(true)
      @usergroup.users << users(:one)
      @usergroup.save

      AuthSourceLdap.any_instance.expects(:users_in_group).with('aname').returns([users(:one).login])
      @usergroup.external_usergroups.find { |eu| eu.name == 'aname'}.refresh
      assert_includes @usergroup.users, users(:one)
    end
  end
end