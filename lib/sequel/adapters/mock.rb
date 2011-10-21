module Sequel
  module Mock
    # Connection class for Sequel's mock adapter.
    class Connection
      # Sequel::Mock::Database object that created this connection
      attr_reader :db

      # Shard this connection operates on, when using Sequel's
      # sharding support (always :default for databases not using
      # sharding).
      attr_reader :server

      # The specific database options for this connection.
      attr_reader :opts

      # Store the db, server, and opts.
      def initialize(db, server, opts)
        @db = db
        @server = server
        @opts = opts
      end

      # Delegate to the db's #_execute method.
      def execute(sql)
        @db.send(:_execute, self, sql) 
      end
    end

    # Database class for Sequel's mock adapter.
    class Database < Sequel::Database
      set_adapter_scheme :mock

      # Set the autogenerated primary key integer
      # to be returned when running an insert query.
      # Argument types supported:
      #
      # nil :: Return nil for all inserts
      # Integer :: Starting integer for next insert, with
      #            futher inserts getting an incremented
      #            value
      # Array :: First insert gets the first value in the
      #          array, second gets the second value, etc.
      # Proc :: Called with the insert SQL query, uses
      #         the value returned
      # Class :: Should be an Exception subclass, will create a new
      #          instance an raise it wrapped in a DatabaseError.
      attr_writer :autoid

      # Set the hashes to yield by execute when retrieving rows.
      # Argument types supported:
      #
      # nil :: Yield no rows
      # Hash :: Always yield a single row with this hash
      # Array of Hashes :: Yield separately for each hash in this array
      # Array (otherwise) :: First retrieval gets the first value
      #          in the array, second gets the second value, etc.
      # Proc :: Called with the select SQL query, uses
      #         the value returned, which should be a hash or
      #         array of hashes.
      # Class :: Should be an Exception subclass, will create a new
      #          instance an raise it wrapped in a DatabaseError.
      attr_writer :fetch

      # Set the number of rows to return from update or delete.
      # Argument types supported:
      #
      # nil :: Return 0 for all updates and deletes
      # Integer :: Used for all updates and deletes
      # Array :: First update/delete gets the first value in the
      #          array, second gets the second value, etc.
      # Proc :: Called with the update/delete SQL query, uses
      #         the value returned.
      # Class :: Should be an Exception subclass, will create a new
      #          instance an raise it wrapped in a DatabaseError.
      attr_writer :numrows

      # Additional options supported:
      #
      # :autoid :: Call #autoid= with the value
      # :fetch ::  Call #fetch= with the value
      # :numrows :: Call #numrows= with the value
      # :extend :: A module the object is extended with.
      # :sqls :: The array to store the SQL queries in.
      def initialize(opts=nil)
        super
        self.autoid = opts[:autoid]
        self.fetch = opts[:fetch]
        self.numrows = opts[:numrows]
        extend(opts[:extend]) if opts[:extend]
        @sqls = opts[:sqls] || []
      end

      # Return a related Connection option connecting to the given shard.
      def connect(server)
        Connection.new(self, server, server_opts(server))
      end

      # Return a Dataset with the given options.
      def dataset(opts={})
        Dataset.new(self, opts)
      end

      # Store the sql used for later retrieval with #sqls, and return
      # the appropriate value using either the #autoid, #fetch, or
      # #numrows methods.
      def execute(sql, opts={}, &block)
        synchronize(opts[:server]){|c| _execute(c, sql, opts, &block)} 
      end
      alias execute_ddl execute

      # Store the sql used, and return the value of the #numrows method.
      def execute_dui(sql, opts={})
        execute(sql, opts.merge(:meth=>:numrows))
      end

      # Store the sql used, and return the value of the #autoid method.
      def execute_insert(sql, opts={})
        execute(sql, opts.merge(:meth=>:autoid))
      end

      # Return all stored SQL queries, and clear the cache
      # of SQL queries.
      def sqls
        s = @sqls.dup
        @sqls.clear
        s
      end

      # Enable use of savepoints.
      def supports_savepoints?
        true
      end

      private

      def _execute(c, sql, opts={}, &block)
        sql += " -- #{@opts[:host]}" if @opts[:host]
        sql += " -- #{c.server}" if c.server != :default
        log_info(sql)
        @sqls << sql 

        begin
          if block
            _fetch(sql, &block)
          elsif meth = opts[:meth]
            send(meth, sql)
          end
        rescue => e
          raise_error(e)
        end
      end

      def _fetch(sql, f=(v=false; nil), &block)
        case (v.nil? ? f : (f ||= @fetch))
        when Hash
          yield f
        when Array
          if f.all?{|h| h.is_a?(Hash)}
            f.each{|h| yield h}
          else
            _fetch(sql, f.shift, &block)
          end
        when Proc
          h = f.call(sql)
          if h.is_a?(Hash)
            yield h
          else
            h.each{|h1| yield h1}
          end
        when Class
          if f < Exception
            raise f
          else
            raise Error, "Invalid @autoid/@numrows attribute: #{v.inspect}"
          end
        when nil
          # nothing
        else
          raise Error, "Invalid @fetch attribute: #{f.inspect}"
        end
      end

      def _nextres(v, sql, default)
        case v
        when Integer
          v
        when Array
          v.empty? ? default : _nextres(v.shift, sql, default)
        when Proc
          v.call(sql)
        when Class
          if v < Exception
            raise v
          else
            raise Error, "Invalid @autoid/@numrows attribute: #{v.inspect}"
          end
        when nil
          default
        else
          raise Error, "Invalid @autoid/@numrows attribute: #{v.inspect}"
        end
      end

      def autoid(sql)
        case v = @autoid
        when Integer
          @autoid += 1
          v
        else
          _nextres(v, sql, nil)
        end
      end

      def numrows(sql)
        _nextres(@numrows, sql, 0)
      end

      def quote_identifiers_default
        false
      end

      def identifier_input_method_default
        nil
      end

      def identifier_input_method_default
        nil
      end
    end

    class Dataset < Sequel::Dataset
      # If arguments are provided, use them to set the columns
      # for this dataset and return self.  Otherwise, use the
      # default Sequel behavior and return the columns.
      def columns(*cs)
        if cs.empty?
          super
        else
          @columns = cs
          self
        end
      end

      alias fetch_rows execute
    end
  end
end
