#!/opt/puppetlabs/puppet/bin/ruby

require 'open3'
require 'json'
require 'syslog/logger'
require 'time'
require 'timeout'

facter = '/opt/puppetlabs/puppet/bin/facter'

log = Syslog::Logger.new 'os_patching'
starttime = Time.now.iso8601

def history(dts, message, code, reboot, security, job)
  historyfile = '/etc/os_patching/run_history'
  open(historyfile, 'a') do |f|
    f.puts "#{dts}|#{message}|#{code}|#{reboot}|#{security}|#{job}"
  end
end

def output(returncode, reboot, security, message, packages_updated, debug, job_id, pinned_packages, starttime)
  endtime = Time.now.iso8601
  json = {
    :return           => returncode,
    :reboot           => reboot,
    :security         => security,
    :message          => message,
    :packages_updated => packages_updated,
    :debug            => debug,
    :job_id           => job_id,
    :pinned_packages  => pinned_packages,
    :start_time       => starttime,
    :end_time         => endtime,
  }
  puts JSON.pretty_generate(json)
  history(starttime, message, returncode, reboot, security, job_id)
end

def err(code, kind, message, starttime)
  endtime = Time.now.iso8601
  exitcode = code.to_s.split.last
  json = {
    :_error =>
    {
      :msg        => "Task exited : #{exitcode}\n#{message}",
      :kind       => kind,
      :details    => { :exitcode => exitcode },
      :start_time => starttime,
      :end_time   => endtime,
    },
  }

  puts JSON.pretty_generate(json)
  shortmsg = message.split("\n").first.chomp
  history(starttime, shortmsg, exitcode, '', '', '')
  log = Syslog::Logger.new 'os_patching'
  log.error "ERROR : #{kind} : #{exitcode} : #{message}"
  exit(exitcode.to_i)
end

# Parse input

params = JSON.parse(STDIN.read)

# Cache fact data to speed things up
log.info 'os_patching run started'
log.debug 'Running os_patching fact refresh'
_fact_out, stderr, status = Open3.capture3('/usr/local/bin/os_patching_fact_generation.sh')
err(status, 'os_patching/fact_refresh', stderr, starttime) if status != 0
log.debug 'Gathering facts'
full_facts, stderr, status = Open3.capture3(facter, '-p', '-j')
err(status, 'os_patching/facter', stderr, starttime) if status != 0
facts = JSON.parse(full_facts)
pinned_pkgs = facts['os_patching']['pinned_packages']

# Should we do a reboot?
if params['reboot']
  if params['reboot'] == 'true'
    reboot = true
  elsif params['reboot'] == 'false'
    reboot = false
  else
    err('108', 'os_patching/params', 'Invalid boolean to reboot parameter', starttime)
  end
else
  reboot = false
end

# Is the reboot_override fact set?
reboot_override = facts['os_patching']['reboot_override']
if reboot_override == 'Invalid Entry'
  err(105, 'os_patching/reboot_override', 'Fact reboot_override invalid', starttime)
elsif reboot_override == true && reboot == false
  log.error 'Reboot override set to true but task said no.  Will reboot'
  reboot = true
elsif reboot_override == false && reboot == true
  log.error 'Reboot override set to false but task said yes.  Will not reboot'
  reboot = false
end

log.debug "Reboot after patching set to #{reboot}"

# Should we only apply security patches?
security_only = ''
if params['security_only']
  if params['security_only'] == 'true'
    security_only = true
  elsif params['security_only'] == 'false'
    security_only = false
  else
    err('109', 'os_patching/params', 'Invalid boolean to security_only parameter', starttime)
  end
else
  security_only = false
end
log.debug "Apply only security patches set to #{security_only}"

# Have we had any yum parameter specified?
yum_params = if params['yum_params']
               params['yum_params']
             else
               ''
             end

# Have we had any dpkg parameter specified?
dpkg_params = if params['dpkg_params']
                params['dpkg_params']
              else
                ''
              end

# Set the timeout for the patch run
if params['timeout']
  if params['timeout'] > 0
    timeout = params['timeout']
  else
    err('121', 'os_patching/timeout', "timeout set to #{timeout} seconds - invalid", starttime)
  end
else
  timeout = 3600
end

# Is the patching blocker flag set?
blocker = facts['os_patching']['blocked']
if blocker.to_s.chomp == 'true'
  # Patching is blocked, list the reasons and error
  # need to error as it SHOULDN'T ever happen if you
  # use the right workflow through tasks.
  log.error 'Patching blocked, not continuing'
  block_reason = facts['os_patching']['blocker_reasons']
  err(100, 'os_patching/blocked', "Patching blocked #{block_reason}", starttime)
end

# Should we look at security or all patches to determine if we need to patch?
# (requires RedHat subscription or Debian based distro... for now)
if security_only == true
  updatecount = facts['os_patching']['security_package_update_count']
  securityflag = '--security'
else
  updatecount = facts['os_patching']['package_update_count']
  securityflag = ''
end

# There are no updates available, exit cleanly
if updatecount.zero?
  output('Success', reboot, security_only, 'No patches to apply', '', '', '', pinned_pkgs, starttime)
  log.info 'No patches to apply, exiting'
  exit(0)
end

yum_output = ''
# Run the patching
if facts['os']['family'] == 'RedHat'
  log.debug 'Running yum upgrade'
  log.error "Starting timeout code : #{timeout}"
  status = ''
  stderr = ''
  pid = ''
  Open3.popen3("/bin/yum #{yum_params} #{securityflag} upgrade -y") do |_i, o, e, w|
    begin
      pid = w.pid
      Timeout.timeout(timeout) do
        until e.eof?
          sleep(1)
          log.debug "yum process #{pid} still running but within timeout threshold, sleeping"
        end
      end
    rescue Timeout::Error
      Process.kill('SIGTERM', pid)
      error = o.read
      err(w.value, 'os_patching/timeout', "yum timeout after #{timeout} seconds : #{error}", starttime)
    end
    status = w.value
    yum_output = o.read
    stderr = e.read
  end
  err(status, 'os_patching/yum', stderr, starttime) if status != 0

  log.debug 'Getting yum job ID'
  yum_id, stderr, status = Open3.capture3("yum history | grep -E \"^[[:space:]]\" | awk '{print $1}' | head -1")
  err(status, 'os_patching/yum', stderr, starttime) if status != 0

  log.debug "Getting yum return code for job #{yum_id.chomp}"
  yum_status, stderr, status = Open3.capture3("yum history info #{yum_id.chomp} | awk '/^Return-Code/ {print $3}'")
  err(status, 'os_patching/yum', stderr, starttime) if status != 0

  log.debug "Getting updated package list  for job #{yum_id.chomp}"
  updated_packages, stderr, status = Open3.capture3("yum history info #{yum_id.chomp} | awk '/Updated/ {print $2}'")
  err(status, 'os_patching/yum', stderr, starttime) if status != 0
  pkg_array = updated_packages.split

  output(yum_status.chomp, reboot, security_only, 'Patching complete', pkg_array, yum_output, yum_id.chomp, pinned_pkgs, starttime)
  log.debug 'Patching complete'
elsif facts['os']['family'] == 'Debian'
  if security_only == true
    log.debug 'Debian upgrades, security only not currently supported'
    err(101, 'os_patching/security_only', 'Security only not supported on Debian at this point', starttime)
  end

  log.debug 'Getting package update list'
  updated_packages, stderr, status = Open3.capture3("apt-get dist-upgrade -s #{dpkg_params} | awk '/^Inst/ {print $2}'")
  err(status, 'os_patching/apt', stderr, starttime) if status != 0
  pkg_array = updated_packages.split

  log.debug 'Running apt update'
  deb_front = 'DEBIAN_FRONTEND=noninteractive'
  deb_opts = '-o Apt::Get::Purge=false -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef --no-install-recommends'
  apt_std_out, stderr, status = Open3.capture3("#{deb_front} apt-get #{dpkg_params} -y #{deb_opts} dist-upgrade")
  err(status, 'os_patching/apt', stderr, starttime) if status != 0

  output('Success', reboot, security_only, 'Patching complete', pkg_array, apt_std_out, '', pinned_pkgs, starttime)
  log.debug 'Patching complete'
else
  log.error 'Unsupported OS - exiting'
  err(200, 'os_patching/unsupported_os', 'Unsupported OS', starttime)
end

log.debug 'Running os_patching fact refresh'
_fact_out, stderr, status = Open3.capture3('/usr/local/bin/os_patching_fact_generation.sh')
err(status, 'os_patching/fact', stderr, starttime) if status != 0

if reboot == true
  log.info 'Rebooting'
  _reboot_out, stderr, status = Open3.capture3('/sbin/shutdown', '-r', '+1')
  err(status, 'os_patching/reboot', stderr, starttime) if status != 0
end
log.info 'os_patching run complete'