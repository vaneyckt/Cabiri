require 'cabiri'

describe "Cabiri" do
  it "should kill the job processes when the main process exits nicely" do
    pipe = IO.pipe
    main_pid = fork do
      # make a queue and add two long processes
      queue = Cabiri::JobQueue.new
      queue.add('1st job') { sleep 1000 }
      queue.add('2nd job') { sleep 1000 }

      # start queue in other thread, as start() is a blocking operation
      Thread.new do
        queue.start(2)
      end

      # wait a while and send the pids of both job processes to the spec process
      sleep 5
      first_job_pid = queue.active_jobs[0].pid
      second_job_pid = queue.active_jobs[1].pid

      pipe[0].close
      pipe[1].sync = true
      pipe[1].puts first_job_pid.to_s
      pipe[1].puts second_job_pid.to_s
      pipe[1].close

      # keep this process active by waiting on the two job processes
      while true
        sleep 1
      end
    end

    # retrieve job pids
    pipe[1].close
    pipe[0].sync = true
    rd = IO.select([pipe[0]])
    job_pids = []
    job_pids << rd[0][0].gets.to_i
    job_pids << rd[0][0].gets.to_i
    pipe[0].close

    # check all processes exist
    process_exists?(main_pid).should be_true
    process_exists?(job_pids[0]).should be_true
    process_exists?(job_pids[1]).should be_true

    # kill parent process nicely
    Process.kill("TERM", main_pid)
    Process.waitpid(main_pid)

    # check all processes are no longer active after a few seconds
    sleep 5
    process_exists?(main_pid).should be_false
    process_exists?(job_pids[0]).should be_false
    process_exists?(job_pids[1]).should be_false
  end

  it "should kill the job processes when the main process exits with a SIGKILL" do
    pipe = IO.pipe
    main_pid = fork do
      # make a queue and add two long processes
      queue = Cabiri::JobQueue.new
      queue.add('1st job') { sleep 1000 }
      queue.add('2nd job') { sleep 1000 }

      # start queue in other thread, as start() is a blocking operation
      Thread.new do
        queue.start(2)
      end

      # wait a while and send the pids of both job processes to the spec process
      sleep 5
      first_job_pid = queue.active_jobs[0].pid
      second_job_pid = queue.active_jobs[1].pid

      pipe[0].close
      pipe[1].sync = true
      pipe[1].puts first_job_pid.to_s
      pipe[1].puts second_job_pid.to_s
      pipe[1].close

      # keep this process active by waiting on the two job processes
      while true
        sleep 1
      end
    end

    # retrieve job pids
    pipe[1].close
    pipe[0].sync = true
    rd = IO.select([pipe[0]])
    job_pids = []
    job_pids << rd[0][0].gets.to_i
    job_pids << rd[0][0].gets.to_i
    pipe[0].close

    # check all processes exist
    process_exists?(main_pid).should be_true
    process_exists?(job_pids[0]).should be_true
    process_exists?(job_pids[1]).should be_true

    # kill parent process with SIGKILL
    Process.kill("KILL", main_pid)
    Process.waitpid(main_pid)

    # check all processes are no longer active after a few seconds
    sleep 5
    process_exists?(main_pid).should be_false
    process_exists?(job_pids[0]).should be_false
    process_exists?(job_pids[1]).should be_false
  end

  it "should run jobs in parallel and return the correct results" do
    queue = Cabiri::JobQueue.new

    queue.add('1st job') do
      sleep 5
      'process A done'
    end

    queue.add('2nd job') do
      sleep 5
      'process B done'
    end

    queue.add('3rd job') do
      sleep 10
      'process C done'
    end

    # start queue in other thread, as start() is a blocking operation
    Thread.new do
      queue.start(2)
    end

    sleep 6
    queue.finished_jobs['1st job'].result.should == 'process A done'
    queue.finished_jobs['2nd job'].result.should == 'process B done'
    queue.finished_jobs['3rd job'].should == nil

    sleep 6
    queue.finished_jobs['3rd job'].should == nil

    sleep 6
    queue.finished_jobs['3rd job'].result.should == 'process C done'
  end
end

def process_exists?(pid)
  begin
    Process.getpgid(pid)
    true
  rescue Errno::ESRCH
    false
  end
end
