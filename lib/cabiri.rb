module Cabiri
  class Job
    attr_accessor :id
    attr_accessor :pid
    attr_accessor :block
    attr_accessor :result
    attr_accessor :pipe
    attr_accessor :lifeline

    def initialize(id, &block)
      @id = id
      @pid = nil
      @block = block
      @result = nil
      @pipe = nil
      @lifeline = nil
    end

    def activate!
      @pipe = IO.pipe
      @lifeline = IO.pipe

      @pid = fork do
        @pipe[0].close
        @pipe[1].sync = true

        @lifeline[1].close
        @lifeline[0].sync = true

        begin
          lifeline_thread = Thread.new(Thread.current) do |main_thread|
            result = IO.select([@lifeline[0]], nil, nil, nil)
            main_thread.raise "Killing job '#{@id}' as connection with parent process was lost."
          end
          result = @block.call
          @pipe[1].puts [Marshal.dump(result)].pack("m")
        rescue => e
          puts "Exception (#{e}) in block: #{@block.inspect}"
        end
      end

      @pipe[1].close
      @pipe[0].sync = true

      @lifeline[0].close
      @lifeline[1].sync = true
    end

    def finish!
      @result = Marshal.load(@pipe[0].read.unpack("m")[0])
      @pipe[0].close
      @lifeline[1].close
      Process.waitpid(@pid)
    end
  end

  class JobQueue
    attr_accessor :pending_jobs
    attr_accessor :active_jobs
    attr_accessor :finished_jobs

    def initialize
      @pending_jobs = []
      @active_jobs = []
      @finished_jobs = {}
    end

    def add(id, &block)
      @pending_jobs << Job.new(id, &block)
    end

    def pending_jobs_available?
      @pending_jobs.length >= 1
    end

    def active_jobs_available?
      @active_jobs.length >= 1
    end

    def finished?
      !pending_jobs_available? && !active_jobs_available?
    end

    def get_read_end_points_of_active_jobs
      read_end_points = []
      @active_jobs.each do |active_job|
        read_end_points << active_job.pipe[0]
      end
      read_end_points
    end

    def get_active_job_by_read_end_point(read_end_point)
      @active_jobs.each do |active_job|
        return active_job if (active_job.pipe[0] == read_end_point)
      end
    end

    def start(max_active_jobs)
      # start by activating as many jobs as allowed
      max_active_jobs.times do
        if pending_jobs_available?
          activate_next_available_job
        end
      end

      while active_jobs_available?
        # every time IO.select gets called, we need to do something
        read_end_points = get_read_end_points_of_active_jobs
        read_end_points_array, _, _ = IO.select(read_end_points, nil, nil, nil)

        # finish all jobs that we got returned data for
        read_end_points_array.each do |read_end_point|
          active_job = get_active_job_by_read_end_point(read_end_point)
          finish_job(active_job)
        end

        # schedule as many new jobs as the number of jobs that just finished
        nb_of_just_finished_jobs = read_end_points_array.length
        nb_of_just_finished_jobs.times do
          if pending_jobs_available?
            activate_next_available_job
          end
        end
      end
    end

    def activate_next_available_job
      job = @pending_jobs.shift
      job.activate!
      @active_jobs << job
    end

    def finish_job(job)
      job = @active_jobs.delete(job)
      job.finish!
      @finished_jobs[job.id] = job
    end
  end
end
