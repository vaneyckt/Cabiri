require 'adeona'
require 'logger'

module Cabiri
  class JobQueue
    # the only thing here that is not self evident is the use of self_pipe.
    # This will be used by the wait_until_finished method to implement a
    # blocking wait. More information can be found in the comments of that
    # method.
    def initialize
      @remaining_jobs = []
      @active_jobs_pids = []

      @self_pipe = IO.pipe()
      @self_pipe[0].sync = true
      @self_pipe[1].sync = true

      @logger = Logger.new($stdout)
    end

    def add(&block)
      @remaining_jobs << block
    end

    def finished?
      @remaining_jobs.empty? and @active_jobs_pids.empty?
    end

    # this is a blocking wait that won't return until after all jobs in the
    # queue are finished. The initialize method has set up a self_pipe. When
    # the last job of the queue is finished, the start method will close the
    # write end of this pipe. This causes the kernel to notice that nothing can
    # write to the pipe anymore and thus the kernel sends an EOF down this pipe,
    # which in turn causes IO.select to return.
    # When IO.select returns we close the read end of the pipe, such that any
    # future calls to the wait_until_finished method can return immediately.
    def wait_until_finished
      if(!@self_pipe[0].closed?)
        IO.select([@self_pipe[0]])
        @self_pipe[0].close
      end
    end

    # here we start by defining a signal handler that deals with SIGCHLD signals
    # (a signal that indicates that a child process has terminated). When we receive
    # such a signal we get the pid and make sure that the child process was one of
    # the jobs belonging to the job queue.
    # This needs to be done inside a while loop as two or more child processes exiting
    # in quick succession might only generate one signal. For example, the first dead
    # child process will generate a SIGCHLD. However, when a second process dies quickly
    # afterwards and the previous SIGCHLD signal has not yet been handled, this second
    # process won't send a second SIGCHLD signal, but will instead assume that the
    # SIGCHLD handler knows to look for multiple dead processes.
    # You might also notice that old_handler is being used to redirect this signal to
    # a possible other previously defined SIGCHLD signal handler.
    # Also note that we close the write end of the self_pipe when there are no jobs left.
    # See the comments on the wait_until_finished method for more information on this.
    def start(max_active_jobs)
      old_handler = trap(:CLD) do
        begin
          while pid = Process.wait(-1, Process::WNOHANG)
            if(@active_jobs_pids.include?(pid))
              @active_jobs_pids.delete(pid)
              fill_job_slots(max_active_jobs)
              @self_pipe[1].close if finished?
            end
            old_handler.call if old_handler.respond_to?(:call)
          end
        rescue Errno::ECHILD
        end
      end

      fill_job_slots(max_active_jobs)
    end

    # here we fill all the empty job slots. When we take a new job two things can happen.
    # Either we manage to successfully spawn a new process or something goes wrong and we log
    # it. In either case we assume that we are done with the job and remove it from the
    # remaining_jobs array.
    def fill_job_slots(max_active_jobs)
      while(@active_jobs_pids.length < max_active_jobs and !@remaining_jobs.empty?)
        begin
          @active_jobs_pids << Adeona.spawn_child(:detach => false) { @remaining_jobs[0].call }
        rescue => ex
          @logger.warn(self.class.to_s) { "Exception thrown when trying to instantiate job. Job info: #{@remaining_jobs[0].to_s}. Exception info: #{ex.to_s}." }
        ensure
          @remaining_jobs.delete_at(0)
        end
      end
    end
  end
end
