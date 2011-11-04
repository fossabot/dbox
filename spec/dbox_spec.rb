# encoding: utf-8

require File.expand_path(File.dirname(__FILE__) + "/spec_helper")

include FileUtils

describe Dbox do
  before(:all) do
    clear_test_log
  end

  before(:each) do
    log.info example.full_description
    @name = randname()
    @local = File.join(LOCAL_TEST_PATH, @name)
    @remote = File.join(REMOTE_TEST_PATH, @name)
  end

  after(:each) do
    log.info ""
  end

  describe "#create" do
    it "creates the local directory" do
      Dbox.create(@remote, @local).should eql(:created => [], :deleted => [], :updated => [""])
      @local.should exist
    end

    it "creates the remote directory" do
      Dbox.create(@remote, @local).should eql(:created => [], :deleted => [], :updated => [""])
      ensure_remote_exists(@remote)
    end

    it "should fail if the remote already exists" do
      Dbox.create(@remote, @local)
      rm_rf @local
      expect { Dbox.create(@remote, @local) }.to raise_error(Dbox::RemoteAlreadyExists)
      @local.should_not exist
    end
  end

  describe "#clone" do
    it "creates the local directory" do
      Dbox.create(@remote, @local)
      rm_rf @local
      @local.should_not exist
      Dbox.clone(@remote, @local).should eql(:created => [], :deleted => [], :updated => [""])
      @local.should exist
    end

    it "should fail if the remote does not exist" do
      expect { Dbox.clone(@remote, @local) }.to raise_error(Dbox::RemoteMissing)
      @local.should_not exist
    end
  end

  describe "#pull" do
    it "should fail if the local dir is missing" do
      expect { Dbox.pull(@local) }.to raise_error(Dbox::DatabaseError)
    end

    it "should fail if the remote dir is missing" do
      Dbox.create(@remote, @local)
      db = Dbox::Database.load(@local)
      db.update_metadata(:remote_path => "/" + randname())
      expect { Dbox.pull(@local) }.to raise_error(Dbox::RemoteMissing)
    end

    it "should be able to pull" do
      Dbox.create(@remote, @local)
      Dbox.pull(@local).should eql(:created => [], :deleted => [], :updated => [])
    end

    it "should be able to pull changes" do
      Dbox.create(@remote, @local)
      "#{@local}/hello.txt".should_not exist

      @alternate = "#{ALTERNATE_LOCAL_TEST_PATH}/#{@name}"
      Dbox.clone(@remote, @alternate)
      make_file "#{@alternate}/hello.txt"
      Dbox.push(@alternate).should eql(:created => ["hello.txt"], :deleted => [], :updated => [])

      Dbox.pull(@local).should eql(:created => ["hello.txt"], :deleted => [], :updated => [""])
      "#{@local}/hello.txt".should exist
    end

    it "should be able to pull after deleting a file and not have the file re-created" do
      Dbox.create(@remote, @local)
      make_file "#{@local}/hello.txt"
      Dbox.push(@local).should eql(:created => ["hello.txt"], :deleted => [], :updated => [])
      rm "#{@local}/hello.txt"
      Dbox.pull(@local).should eql(:created => [], :deleted => [], :updated => [""])
      "#{@local}/hello.txt".should_not exist
    end

    it "should handle a complex set of changes" do
      Dbox.create(@remote, @local)

      @alternate = "#{ALTERNATE_LOCAL_TEST_PATH}/#{@name}"
      Dbox.clone(@remote, @alternate)

      Dbox.pull(@local).should eql(:created => [], :deleted => [], :updated => [])

      make_file "#{@alternate}/foo.txt"
      make_file "#{@alternate}/bar.txt"
      make_file "#{@alternate}/baz.txt"
      Dbox.push(@alternate).should eql(:created => ["bar.txt", "baz.txt", "foo.txt"], :deleted => [], :updated => [])
      Dbox.pull(@alternate).should eql(:created => [], :deleted => [], :updated => [""])
      Dbox.pull(@alternate).should eql(:created => [], :deleted => [], :updated => [])

      Dbox.pull(@local).should eql(:created => ["bar.txt", "baz.txt", "foo.txt"], :deleted => [], :updated => [""])
      Dbox.pull(@local).should eql(:created => [], :deleted => [], :updated => [])

      mkdir "#{@alternate}/subdir"
      make_file "#{@alternate}/subdir/one.txt"
      rm "#{@alternate}/foo.txt"
      make_file "#{@alternate}/baz.txt"
      Dbox.push(@alternate).should eql(:created => ["subdir", "subdir/one.txt"], :deleted => ["foo.txt"], :updated => ["baz.txt"])
      Dbox.pull(@alternate).should eql(:created => [], :deleted => [], :updated => ["", "subdir"])
      Dbox.pull(@alternate).should eql(:created => [], :deleted => [], :updated => [])

      Dbox.pull(@local).should eql(:created => ["subdir", "subdir/one.txt"], :deleted => ["foo.txt"], :updated => ["", "baz.txt"])
      Dbox.pull(@local).should eql(:created => [], :deleted => [], :updated => [])
    end
  end

  describe "#push" do
    it "should fail if the local dir is missing" do
      expect { Dbox.push(@local) }.to raise_error(Dbox::DatabaseError)
    end

    it "should be able to push" do
      Dbox.create(@remote, @local)
      Dbox.push(@local).should eql(:created => [], :deleted => [], :updated => [])
    end

    it "should be able to push a new file" do
      Dbox.create(@remote, @local)
      make_file "#{@local}/foo.txt"
      Dbox.push(@local).should eql(:created => ["foo.txt"], :deleted => [], :updated => [])
    end

    it "should be able to push a new dir" do
      Dbox.create(@remote, @local)
      mkdir "#{@local}/subdir"
      Dbox.push(@local).should eql(:created => ["subdir"], :deleted => [], :updated => [])
    end

    it "should be able to push a new dir with a file in it" do
      Dbox.create(@remote, @local)
      mkdir "#{@local}/subdir"
      make_file "#{@local}/subdir/foo.txt"
      Dbox.push(@local).should eql(:created => ["subdir", "subdir/foo.txt"], :deleted => [], :updated => [])
    end

    it "should be able to push a new file in an existing dir" do
      Dbox.create(@remote, @local)
      mkdir "#{@local}/subdir"
      Dbox.push(@local)
      make_file "#{@local}/subdir/foo.txt"
      Dbox.push(@local).should eql(:created => ["subdir/foo.txt"], :deleted => [], :updated => [])
    end

    it "should create the remote dir if it is missing" do
      Dbox.create(@remote, @local)
      make_file "#{@local}/foo.txt"
      @new_name = randname()
      @new_remote = File.join(REMOTE_TEST_PATH, @new_name)
      db = Dbox::Database.load(@local)
      db.update_metadata(:remote_path => @new_remote)
      Dbox.push(@local).should eql(:created => ["foo.txt"], :deleted => [], :updated => [])
    end

    it "should not re-download the file after creating" do
      Dbox.create(@remote, @local)
      make_file "#{@local}/foo.txt"
      Dbox.push(@local).should eql(:created => ["foo.txt"], :deleted => [], :updated => [])
      Dbox.pull(@local).should eql(:created => [], :deleted => [], :updated => [""])
    end

    it "should not re-download the file after updating" do
      Dbox.create(@remote, @local)
      make_file "#{@local}/foo.txt"
      Dbox.push(@local).should eql(:created => ["foo.txt"], :deleted => [], :updated => [])
      sleep 1 # need to wait for timestamp to change before writing same file
      make_file "#{@local}/foo.txt"
      Dbox.push(@local).should eql(:created => [], :deleted => [], :updated => ["foo.txt"])
      Dbox.pull(@local).should eql(:created => [], :deleted => [], :updated => [""])
    end

    it "should not re-download the dir after creating" do
      Dbox.create(@remote, @local)
      mkdir "#{@local}/subdir"
      Dbox.push(@local).should eql(:created => ["subdir"], :deleted => [], :updated => [])
      Dbox.pull(@local).should eql(:created => [], :deleted => [], :updated => [""])
    end

    it "should handle a complex set of changes" do
      Dbox.create(@remote, @local)
      make_file "#{@local}/foo.txt"
      make_file "#{@local}/bar.txt"
      make_file "#{@local}/baz.txt"
      Dbox.push(@local).should eql(:created => ["bar.txt", "baz.txt", "foo.txt"], :deleted => [], :updated => [])
      sleep 1 # need to wait for timestamp to change before writing same file
      mkdir "#{@local}/subdir"
      make_file "#{@local}/subdir/one.txt"
      rm "#{@local}/foo.txt"
      make_file "#{@local}/baz.txt"
      Dbox.push(@local).should eql(:created => ["subdir", "subdir/one.txt"], :deleted => ["foo.txt"], :updated => ["baz.txt"])
      Dbox.pull(@local).should eql(:created => [], :deleted => [], :updated => ["", "subdir"])
    end

    it "should be able to handle crazy filenames" do
      Dbox.create(@remote, @local)
      crazy_name1 = '=+!@#  $%^&*()[]{}<>_-|:?,\'~".txt'
      crazy_name2 = '[ˈdɔʏtʃ].txt'
      make_file "#{@local}/#{crazy_name1}"
      make_file "#{@local}/#{crazy_name2}"
      Dbox.push(@local).should eql(:created => [crazy_name1, crazy_name2], :deleted => [], :updated => [])
      rm_rf @local
      Dbox.clone(@remote, @local).should eql(:created => [crazy_name1, crazy_name2], :deleted => [], :updated => [""])
    end

    it "should be able to handle crazy directory names" do
      Dbox.create(@remote, @local)
      crazy_name1 = "Day[J] #42"
      mkdir File.join(@local, crazy_name1)
      make_file File.join(@local, crazy_name1, "foo.txt")
      Dbox.push(@local).should eql(:created => [crazy_name1, File.join(crazy_name1, "foo.txt")], :deleted => [], :updated => [])
      rm_rf @local
      Dbox.clone(@remote, @local).should eql(:created => [crazy_name1, File.join(crazy_name1, "foo.txt")], :deleted => [], :updated => [""])
    end
  end

  describe "#move" do
    before(:each) do
      @new_name = randname()
      @new_local = File.join(LOCAL_TEST_PATH, @new_name)
      @new_remote = File.join(REMOTE_TEST_PATH, @new_name)
    end

    it "should fail if the local dir is missing" do
      expect { Dbox.move(@new_remote, @local) }.to raise_error(Dbox::DatabaseError)
    end

    it "should be able to move" do
      Dbox.create(@remote, @local)
      expect { Dbox.move(@new_remote, @local) }.to_not raise_error
      @local.should exist
      expect { Dbox.clone(@new_remote, @new_local) }.to_not raise_error
      @new_local.should exist
    end

    it "should not be able to move to a location that exists" do
      Dbox.create(@remote, @local)
      Dbox.create(@new_remote, @new_local)
      expect { Dbox.move(@new_remote, @local) }.to raise_error(Dbox::RemoteAlreadyExists)
    end
  end

  describe "#exists?" do
    it "should be false if the local dir is missing" do
      Dbox.exists?(@local).should be_false
    end

    it "should be true if the dir exists" do
      Dbox.create(@remote, @local)
      Dbox.exists?(@local).should be_true
    end

    it "should be false if the dir exists but is missing a .dbox.sqlite3 file" do
      Dbox.create(@remote, @local)
      rm "#{@local}/.dbox.sqlite3"
      Dbox.exists?(@local).should be_false
    end
  end

  describe "misc" do
    it "should be able to recreate a dir after deleting it" do
      Dbox.create(@remote, @local)

      @alternate = "#{ALTERNATE_LOCAL_TEST_PATH}/#{@name}"
      Dbox.clone(@remote, @alternate)

      Dbox.pull(@local).should eql(:created => [], :deleted => [], :updated => [])

      mkdir "#{@local}/subdir"
      make_file "#{@local}/subdir/one.txt"
      Dbox.push(@local).should eql(:created => ["subdir", "subdir/one.txt"], :deleted => [], :updated => [])

      Dbox.pull(@alternate).should eql(:created => ["subdir", "subdir/one.txt"], :deleted => [], :updated => [""])

      rm_rf "#{@alternate}/subdir"
      Dbox.push(@alternate).should eql(:created => [], :deleted => ["subdir"], :updated => [])

      Dbox.pull(@local).should eql(:created => [], :deleted => ["subdir"], :updated => [""])

      sleep 1 # need to wait for timestamp to change before writing same file
      mkdir "#{@local}/subdir"
      make_file "#{@local}/subdir/one.txt"
      Dbox.push(@local).should eql(:created => ["subdir", "subdir/one.txt"], :deleted => [], :updated => [])

      Dbox.pull(@alternate).should eql(:created => ["subdir", "subdir/one.txt"], :deleted => [], :updated => [""])
    end
  end
end
