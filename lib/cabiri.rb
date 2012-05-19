require 'adeona'
require 'logger'

module Cabiri
  class JobQueue
    # - remaining_jobs:   array that contains jobs that have yet to run
    # - active_job_pids:  array that contains the pids of jobs that are currently running
    # - jobs_info:        array that keeps track of the state of each job
    # - pid_to_index:     hash that maps the pid of a job to an index in the jobs_info array
    # - uid_to_index:     hash that maps the uid of a job to an index in the jobs_info array
    # - self_pipe:        a pipe that is used by the main process to implement a blocking wait for the
    #                     wait_until_finished method. Both endpoints have sync set to true to prevent the
    #                     kernel from buffering any messages.
    # - mutex:            a mutex that is used to treat the code that deals with extracting results from
    #                     finished processes and spawning new processes as a critical section
    # - logger:           a logger to help log errors
    def initialize
      @remaining_jobs = []
      @active_jobs_pids = []

      @jobs_info = []
      @pid_to_index = {}
      @uid_to_index = {}

      @self_pipe = IO.pipe()
      @self_pipe[0].sync = true
      @self_pipe[1].sync = true

      @mutex = Mutex.new
      @logger = Logger.new($stdout)
    end

    # add a job to the remaining_jobs array
    def add(&block)
      @remaining_jobs << block
    end

    # check if there is more work to be done. The work is finished if there are no jobs waiting to be run
    # and there are no jobs currently being run.
    def finished?
      @remaining_jobs.empty? and @active_jobs_pids.empty?
    end

    # this is a blocking wait that won't return until after all jobs in the
    # queue are finished. The initialize method has set up a self_pipe. When
    # the last job of the queue is finished, the start method will close the
    # write end of this pipe. This causes the kernel to notice that nothing can
    # write to the pipe anymore and thus the kernel sends an EOF down this pipe,
    # which in turn causes the blocking IO.select to return.
    # When IO.select returns we close the read end of the pipe, such that any
    # future calls to the wait_until_finished method can return immediately.
    def wait_until_finished
      if(!@self_pipe[0].closed?)
        IO.select([@self_pipe[0]])
        @self_pipe[0].close
      end
    end

    # here we start by creating a uid to index mapping and add an entry for each
    # job to the jobs_info array. We then schedule the first batch of jobs.
    def start(max_active_jobs)
      # create job mappings and initialize job info
      @remaining_jobs.each_with_index do |job, index|
        uid = job.to_s
        @uid_to_index[uid] = index

        @jobs_info[index] = {}
        @jobs_info[index][:pid] = nil
        @jobs_info[index][:pipe] = nil
        @jobs_info[index][:error] = nil
        @jobs_info[index][:result] = nil
        @jobs_info[index][:state] = :waiting
      end

      # start scheduling first batch of jobs
      fill_job_slots(max_active_jobs)
    end

    # here we fill all the empty job slots. When we take a new job two things can happen.
    # Either we manage to successfully spawn a new process or something goes wrong and we log
    # it. In either case we assume that we are done with the job and remove it from the
    # remaining_jobs array.
    def fill_job_slots(max_active_jobs)
      while(@active_jobs_pids.length < max_active_jobs and !@remaining_jobs.empty?)
        begin
          start_next_job(max_active_jobs)
        rescue => ex
          handle_error(ex)
        ensure
          @remaining_jobs.shift
        end
      end
    end

    # when starting a new job we first create a pipe. This pipe will be our mechanism to pass any
    # data returned by the job process to the main process. Next, we create a job process by using
    # the Adeona gem. The spawn_child method acts like fork(), but adds some extra protection to
    # prevent orphaned processes. Inside this job process we close the read endpoint of the pipe and
    # set sync to true for the write endpoint in order to prevent the kernel from buffering any messages.
    # We continue by letting the job do its work and storing the result in a var called 'result'. The
    # next step looks a bit weird. We mentioned that we want to use pipes to communicate data, but pipes
    # weren't designed to transport data structures like arrays and hashes, instead they are meant for text.
    # So we use a trick. We use Marshal.dump to convert our result (which could be an array, a number,
    # a hash - we don't know) into a byte stream, put this information inside an array, and then convert this
    # array into a special string designed for transporting binary data as text. This text can now be send
    # through the write endpoint of the pipe. Back outside the job process we close the write endpoint of the
    # pipe and set sync to true. The next few lines hould require no comment.
    # We finish by creating a thread that waits for the newly created job to end. This thread is responsible
    # for extracting information from the finished job and spawning new jobs. Also note that we close the
    # write end of the self_pipe when there are no jobs left. See the comments on the wait_until_finished
    # method for why this is important.
    # Notice how the inside of the thread is wrapped inside a mutex. This is required to prevent a race
    # condition from occurring when two or more jobs return in quick succession. When the first job
    # returns, its thread will start scheduling new processes, but this can take some time. If a second
    # job returns before the thread of the first job is done scheduling, it will start doing scheduling
    # work as well. So now you have two threads simultaneously doing scheduling work, and the end result
    # will be unpredictable.
    def start_next_job(max_active_jobs)
      pipe = IO.pipe()
      job = @remaining_jobs.first

      pid = Adeona.spawn_child(:detach => false) do
        pipe[0].close
        pipe[1].sync = true
        result = job.call
        pipe[1].puts [Marshal.dump(result)].pack("m")
      end
      pipe[1].close
      pipe[0].sync = true

      index = @uid_to_index[job.to_s]
      @active_jobs_pids << pid
      @pid_to_index[pid] = index

      @jobs_info[index][:pid] = pid
      @jobs_info[index][:pipe] = pipe
      @jobs_info[index][:state] = :running

      Thread.new(pid) do |my_pid|
        Process.waitpid(my_pid)
        @mutex.synchronize do
          handle_finished_job(my_pid)
          fill_job_slots(max_active_jobs)
          @self_pipe[1].close if finished?
        end
      end
    end

    # when a job finishes, we remove its pid from the array that keeps track of active processes.
    # Next we read the result that we sent over the pipe and then close the pipe's read endpoint.
    # We take the received text data, turn it into a byte stream and then load this information
    # in order to obtain the resulting data from the job.
    def handle_finished_job(pid)
      index = @pid_to_index[pid]
      @active_jobs_pids.delete(pid)

      pipe = @jobs_info[index][:pipe]
      result = pipe[0].read
      pipe[0].close

      @jobs_info[index][:result] = Marshal.load(result.unpack("m")[0])
      @jobs_info[index][:state] = :finished
    end

    # when there is an exception, we log the error and set the relevant fields in the jobs_info data
    def handle_error(ex)
      job = @remaining_jobs.first
      index = @uid_to_index[job.to_s]

      error = "Exception thrown when trying to instantiate job. Job info: #{@remaining_jobs.first.to_s}. Exception info: #{ex.to_s}."
      @logger.warn(self.class.to_s) { error }

      @jobs_info[index][:error] = error
      @jobs_info[index][:state] = :error
    end

    # this allows users to query the state of their jobs
    def get_info(index)
      @jobs_info[index]
    end
  end
end
