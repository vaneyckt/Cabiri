require 'cabiri'

describe "Cabiri" do
  it "should kill the job processes when the main process exits nicely" do
    pipe = IO.pipe
    main_pid = fork do
      # make a queue and start running two long processes
      queue = Cabiri::JobQueue.new
      queue.add { sleep 1000 }
      queue.add { sleep 1000 }
      queue.start(2)

      # wait a while and send the pids of both job processes to the spec process
      sleep 5
      pipe[0].close
      pipe[1].sync = true
      pipe[1].puts queue.get_info(0)[:pid].to_s
      pipe[1].puts queue.get_info(1)[:pid].to_s
      pipe[1].close

      # keep this process active by waiting on the two job processes
      queue.wait_until_finished
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
      # make a queue and start running two long processes
      queue = Cabiri::JobQueue.new
      queue.add { sleep 1000 }
      queue.add { sleep 1000 }
      queue.start(2)

      # wait a while and send the pids of both job processes to the spec process
      sleep 5
      pipe[0].close
      pipe[1].sync = true
      pipe[1].puts queue.get_info(0)[:pid].to_s
      pipe[1].puts queue.get_info(1)[:pid].to_s
      pipe[1].close

      # keep this process active by waiting on the two job processes
      queue.wait_until_finished
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

    queue.add do
      sleep 5
      'process A done'
    end

    queue.add do
      sleep 5
      'process B done'
    end

    queue.add do
      sleep 10
      'process C done'
    end

    queue.start(2)

    sleep 6
    queue.get_info(0)[:result].should == 'process A done'
    queue.get_info(1)[:result].should == 'process B done'
    queue.get_info(2)[:result].should_not == 'process C done'

    sleep 6
    queue.get_info(2)[:result].should_not == 'process C done'

    sleep 6
    queue.get_info(2)[:result].should == 'process C done'
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
