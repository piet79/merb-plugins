task :environment do
 MERB_ENV = ( ENV['MERB_ENV'] || MERB_ENV ).to_sym
end

namespace :db do
  namespace :create do
    desc 'Create all the local databases defined in config/database.yml'
    task :all => :environment do
      ActiveRecord::Base.configurations.each_value do |config|
        create_local_database(config)
      end
    end
  end

  desc 'Create the local database defined in config/database.yml for the current MERB_ENV'
  task :create => :environment do
    p ActiveRecord::Base.configurations
    p MERB_ENV
    create_local_database(ActiveRecord::Base.configurations[MERB_ENV])
  end

  def create_local_database(config)
    # Only connect to local databases
    if config[:host] == 'localhost' || config[:host].blank?
      begin
        ActiveRecord::Base.establish_connection(config)
        ActiveRecord::Base.connection
      rescue
        case config[:adapter]
        when 'mysql'
          #~ @charset   = ENV['CHARSET']   || 'utf8'
          #~ @collation = ENV['COLLATION'] || 'utf8_general_ci'
          begin
            ActiveRecord::Base.establish_connection(config.merge({:database => nil}))
            ActiveRecord::Base.connection.create_database(config[:database]) #, {:charset => @charset, :collation => @collation})
            ActiveRecord::Base.establish_connection(config)
            p "MySQL #{config[:database]} database succesfully created"
          rescue
            $stderr.puts "Couldn't create database for #{config.inspect}"
          end
        when 'postgresql'
          `createdb "#{config[:database]}" -E utf8`
        when 'sqlite'
          `sqlite "#{config[:database]}"`
        when 'sqlite3'
          `sqlite3 "#{config[:database]}"`
        end
      else
        p "#{config[:database]} already exists"
      end
    else
      p "This task only creates local databases. #{config[:database]} is on a remote host."
    end
  end

  desc 'Drops the database for the current environment'
  task :drop => :environment do
    config = ActiveRecord::Base.configurations[MERB_ENV || :development]
    p config
    case config[:adapter]
    when 'mysql'
      ActiveRecord::Base.connection.drop_database config[:database]
    when /^sqlite/
      FileUtils.rm_f File.join(MERB_ROOT, config[:database])
    when 'postgresql'
      `dropdb "#{config[:database]}"`
    end
  end

  desc "Migrate the database through scripts in schema/migrations. Target specific version with VERSION=x"
  task :migrate => :environment do
    ActiveRecord::Migrator.migrate("schema/migrations/", ENV["VERSION"] ? ENV["VERSION"].to_i : nil)
    Rake::Task["db:schema:dump"].invoke if ActiveRecord::Base.schema_format == :ruby
  end

  desc 'Drops, creates and then migrates the database for the current environment. Target specific version with VERSION=x'
  task :reset => ['db:drop', 'db:create', 'db:migrate']

  # desc "Retrieves the charset for the current environment's database"
  # task :charset => :environment do
  #   config = ActiveRecord::Base.configurations[MERB_ENV || :development]
  #   case config[:adapter]
  #   when 'mysql'
  #     ActiveRecord::Base.establish_connection(config)
  #     puts ActiveRecord::Base.connection.charset
  #   else
  #     puts 'sorry, your database adapter is not supported yet, feel free to submit a patch'
  #   end
  # end

  # desc "Retrieves the collation for the current environment's database"
  # task :collation => :environment do
  #   config = ActiveRecord::Base.configurations[MERB_ENV || :development]
  #   case config[:adapter]
  #   when 'mysql'
  #     ActiveRecord::Base.establish_connection(config)
  #     puts ActiveRecord::Base.connection.collation
  #   else
  #     puts 'sorry, your database adapter is not supported yet, feel free to submit a patch'
  #   end
  # end

  desc "Retrieves the current schema version number"
  task :version => :environment do
    puts "Current version: #{ActiveRecord::Migrator.current_version}"
  end

  namespace :fixtures do
    desc "Load fixtures into the current environment's database.  Load specific fixtures using FIXTURES=x,y"
    task :load => :environment do
      require 'active_record/fixtures'
      ActiveRecord::Base.establish_connection(MERB_ENV.to_sym)
      (ENV['FIXTURES'] ? ENV['FIXTURES'].split(/,/) : Dir.glob(File.join(MERB_ROOT, 'test', 'fixtures', '*.{yml,csv}'))).each do |fixture_file|
        Fixtures.create_fixtures('test/fixtures', File.basename(fixture_file, '.*'))
      end
    end
  end

  namespace :schema do
    desc "Create a schema/schema.rb file that can be portably used against any DB supported by AR"
    task :dump => :environment do
      require 'active_record/schema_dumper'
      File.open(ENV['SCHEMA'] || "schema/schema.rb", "w") do |file|
        ActiveRecord::SchemaDumper.dump(ActiveRecord::Base.connection, file)
      end
    end

    desc "Load a schema.rb file into the database"
    task :load => :environment do
      file = ENV['SCHEMA'] || "schema/schema.rb"
      load(file)
    end
  end

  namespace :structure do
    desc "Dump the database structure to a SQL file"
    task :dump => :environment do
      abcs = ActiveRecord::Base.configurations
      case abcs[MERB_ENV][:adapter]
      when "mysql", "oci", "oracle"
        ActiveRecord::Base.establish_connection(abcs[MERB_ENV])
        File.open("schema/#{MERB_ENV}_structure.sql", "w+") { |f| f << ActiveRecord::Base.connection.structure_dump }
      when "postgresql"
        ENV['PGHOST']     = abcs[MERB_ENV]["host"] if abcs[MERB_ENV]["host"]
        ENV['PGPORT']     = abcs[MERB_ENV]["port"].to_s if abcs[MERB_ENV]["port"]
        ENV['PGPASSWORD'] = abcs[MERB_ENV]["password"].to_s if abcs[MERB_ENV]["password"]
        search_path = abcs[MERB_ENV]["schema_search_path"]
        search_path = "--schema=#{search_path}" if search_path
        `pg_dump -i -U "#{abcs[MERB_ENV]["username"]}" -s -x -O -f schema/#{MERB_ENV}_structure.sql #{search_path} #{abcs[MERB_ENV]["database"]}`
        raise "Error dumping database" if $?.exitstatus == 1
      when "sqlite", "sqlite3"
        dbfile = abcs[MERB_ENV]["database"] || abcs[MERB_ENV]["dbfile"]
        `#{abcs[MERB_ENV]["adapter"]} #{dbfile} .schema > schema/#{MERB_ENV}_structure.sql`
      when "sqlserver"
        `scptxfr /s #{abcs[MERB_ENV]["host"]} /d #{abcs[MERB_ENV]["database"]} /I /f db\\#{MERB_ENV}_structure.sql /q /A /r`
        `scptxfr /s #{abcs[MERB_ENV]["host"]} /d #{abcs[MERB_ENV]["database"]} /I /F db\ /q /A /r`
      when "firebird"
        set_firebird_env(abcs[MERB_ENV])
        db_string = firebird_db_string(abcs[MERB_ENV])
        sh "isql -a #{db_string} > schema/#{MERB_ENV}_structure.sql"
      else
        raise "Task not supported by '#{abcs[MERB_ENV][:adapter]}'"
      end

      if ActiveRecord::Base.connection.supports_migrations?
        File.open("schema/#{MERB_ENV}_structure.sql", "a") { |f| f << ActiveRecord::Base.connection.dump_schema_information }
      end
    end
  end

  namespace :test do
    desc "Recreate the test database from the current environment's database schema"
    task :clone => %w(db:schema:dump db:test:purge) do
      ActiveRecord::Base.establish_connection(ActiveRecord::Base.configurations['test'])
      ActiveRecord::Schema.verbose = false
      Rake::Task["db:schema:load"].invoke
    end


    desc "Recreate the test databases from the development structure"
    task :clone_structure => [ "db:structure:dump", "db:test:purge" ] do
      abcs = ActiveRecord::Base.configurations
      case abcs["test"]["adapter"]
      when "mysql"
        ActiveRecord::Base.establish_connection(:test)
        ActiveRecord::Base.connection.execute('SET foreign_key_checks = 0')
        IO.readlines("schema/#{MERB_ENV}_structure.sql").join.split("\n\n").each do |table|
          ActiveRecord::Base.connection.execute(table)
        end
      when "postgresql"
        ENV['PGHOST']     = abcs["test"]["host"] if abcs["test"]["host"]
        ENV['PGPORT']     = abcs["test"]["port"].to_s if abcs["test"]["port"]
        ENV['PGPASSWORD'] = abcs["test"]["password"].to_s if abcs["test"]["password"]
        `psql -U "#{abcs["test"]["username"]}" -f schema/#{MERB_ENV}_structure.sql #{abcs["test"]["database"]}`
      when "sqlite", "sqlite3"
        dbfile = abcs["test"]["database"] || abcs["test"]["dbfile"]
        `#{abcs["test"]["adapter"]} #{dbfile} < schema/#{MERB_ENV}_structure.sql`
      when "sqlserver"
        `osql -E -S #{abcs["test"]["host"]} -d #{abcs["test"]["database"]} -i db\\#{MERB_ENV}_structure.sql`
      when "oci", "oracle"
        ActiveRecord::Base.establish_connection(:test)
        IO.readlines("schema/#{MERB_ENV}_structure.sql").join.split(";\n\n").each do |ddl|
          ActiveRecord::Base.connection.execute(ddl)
        end
      when "firebird"
        set_firebird_env(abcs["test"])
        db_string = firebird_db_string(abcs["test"])
        sh "isql -i schema/#{MERB_ENV}_structure.sql #{db_string}"
      else
        raise "Task not supported by '#{abcs["test"]["adapter"]}'"
      end
    end

    desc "Empty the test database"
    task :purge => :environment do
      abcs = ActiveRecord::Base.configurations
      case abcs["test"]["adapter"]
      when "mysql"
        ActiveRecord::Base.establish_connection(:test)
        ActiveRecord::Base.connection.recreate_database(abcs["test"]["database"])
      when "postgresql"
        ENV['PGHOST']     = abcs["test"]["host"] if abcs["test"]["host"]
        ENV['PGPORT']     = abcs["test"]["port"].to_s if abcs["test"]["port"]
        ENV['PGPASSWORD'] = abcs["test"]["password"].to_s if abcs["test"]["password"]
        enc_option = "-E #{abcs["test"]["encoding"]}" if abcs["test"]["encoding"]

        ActiveRecord::Base.clear_active_connections!
        `dropdb -U "#{abcs["test"]["username"]}" #{abcs["test"]["database"]}`
        `createdb #{enc_option} -U "#{abcs["test"]["username"]}" #{abcs["test"]["database"]}`
      when "sqlite","sqlite3"
        dbfile = abcs["test"]["database"] || abcs["test"]["dbfile"]
        File.delete(dbfile) if File.exist?(dbfile)
      when "sqlserver"
        dropfkscript = "#{abcs["test"]["host"]}.#{abcs["test"]["database"]}.DP1".gsub(/\\/,'-')
        `osql -E -S #{abcs["test"]["host"]} -d #{abcs["test"]["database"]} -i db\\#{dropfkscript}`
        `osql -E -S #{abcs["test"]["host"]} -d #{abcs["test"]["database"]} -i db\\#{MERB_ENV}_structure.sql`
      when "oci", "oracle"
        ActiveRecord::Base.establish_connection(:test)
        ActiveRecord::Base.connection.structure_drop.split(";\n\n").each do |ddl|
          ActiveRecord::Base.connection.execute(ddl)
        end
      when "firebird"
        ActiveRecord::Base.establish_connection(:test)
        ActiveRecord::Base.connection.recreate_database!
      else
        raise "Task not supported by '#{abcs["test"]["adapter"]}'"
      end
    end

    desc 'Prepare the test database and load the schema'
    task :prepare => :environment do
      if defined?(ActiveRecord::Base) && !ActiveRecord::Base.configurations.blank?
        Rake::Task[{ :sql  => "db:test:clone_structure", :ruby => "db:test:clone" }[ActiveRecord::Base.schema_format]].invoke
      end
    end
  end

  namespace :sessions do
  #  desc "Creates a sessions migration for use with CGI::Session::ActiveRecordStore"
  #  task :create => :environment do
  #    raise "Task unavailable to this database (no migration support)" unless ActiveRecord::Base.connection.supports_migrations?
  #    require 'rails_generator'
  #    require 'rails_generator/scripts/generate'
  #    Rails::Generator::Scripts::Generate.new.run(["session_migration", ENV["MIGRATION"] || "AddSessions"])
  #  end

    desc "Clear the sessions table"
    task :clear => :environment do
      session_table = 'session'
      session_table = Inflector.pluralize(session_table) if ActiveRecord::Base.pluralize_table_names
      ActiveRecord::Base.connection.execute "DELETE FROM #{session_table}"
    end
  end
end

def session_table_name
  ActiveRecord::Base.pluralize_table_names ? :sessions : :session
end

def set_firebird_env(config)
  ENV["ISC_USER"]     = config["username"].to_s if config["username"]
  ENV["ISC_PASSWORD"] = config["password"].to_s if config["password"]
end

def firebird_db_string(config)
  FireRuby::Database.db_string_for(config.symbolize_keys)
end
