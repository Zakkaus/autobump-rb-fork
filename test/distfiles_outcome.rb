#!/usr/bin/env ruby
# frozen_string_literal: true
require 'fileutils'
require 'stringio'
require 'tmpdir'
require_relative '../lib/autobump'

$fail = 0
def check(name, got, want)
  if got == want
    puts "ok   #{name}"
  else
    $fail += 1
    puts "FAIL #{name}\n       got  #{got.inspect}\n       want #{want.inspect}"
  end
end

TestConfig = Struct.new(:op_timeout, :sudo)

# when the issue started naming the target version; nil stands for GitHub not answering
$seen = nil
Autobump::Issue.define_singleton_method(:version_seen_at) { |_cfg, _issue| $seen }
MIRRORS = 'https://distfiles.gentoo.org/distfiles https://mirror.example/gentoo'

def manifest_error(log, code: 1, issue: nil, seen: nil)
  $seen = seen
  Dir.mktmpdir('autobump-distfiles-outcome-') do |pkgdir|
    bindir = File.join(pkgdir, 'bin')
    Dir.mkdir(bindir)
    portageq = File.join(bindir, 'portageq')
    File.write(portageq, "#!/bin/sh\nprintf '%s\\n' '#{MIRRORS}'\n")
    File.chmod(0o755, portageq)

    old = File.join(pkgdir, 'pkg-1.0.ebuild')
    neweb = File.join(pkgdir, 'pkg-1.1.ebuild')
    File.write(old, "EAPI=8\n")
    evidence = Autobump::Evidence.new('distfiles-outcome')
    context = Autobump::Context.new(
      cfg: TestConfig.new(30, ''), pkgdir: pkgdir, newver: '1.1', issue: issue,
      old_ebuild: old, new_ebuild: neweb, evidence: evidence
    )
    replies = {
      %w[ebuild pkg-1.0.ebuild fetch] => ['', true, 0],
      %w[ebuild pkg-1.1.ebuild manifest] => [log, false, code]
    }
    context.define_singleton_method(:sh) do |*command, **options|
      replies.fetch(command) { raise "unexpected command: #{command.inspect} #{options.inspect}" }
    end

    old_path = ENV['PATH']
    stdout = $stdout
    ENV['PATH'] = bindir
    $stdout = StringIO.new
    begin
      Autobump::Distfiles.new(context).run
      nil
    rescue Autobump::Abort, Autobump::Escalate => e
      $reason = e.message
      e.class
    ensure
      $stdout = stdout
      ENV['PATH'] = old_path
      FileUtils.rm_rf(evidence.dir)
    end
  end
end

check 'a local manifest defect escalates',
      manifest_error("Permission denied\nerror sourcing ebuild\nNo space left on device\ncommand not found\n"),
      Autobump::Escalate

upstream_404 = <<~LOG
  >>> Downloading 'https://upstream.example/pkg-1.1.tar.gz'
  ERROR 404: Not Found.
LOG
check "the ebuild's own URI answering 404 escalates",
      manifest_error(upstream_404), Autobump::Escalate

mirror_404_then_timeout = <<~LOG
  >>> Downloading 'https://distfiles.gentoo.org/distfiles/23/pkg-1.1.tar.gz'
  ERROR 404: Not Found.
  >>> Downloading 'https://upstream.example/pkg-1.1.tar.gz'
  Connecting to upstream.example|10.255.255.1|:443... failed: Connection timed out.
LOG
check 'a mirror 404 plus upstream timeout defers',
      manifest_error(mirror_404_then_timeout), Autobump::Abort

fresh = Time.now - 3600
stale = Time.now - Autobump::Distfiles::UNPUBLISHED_GRACE - 60
check 'a 404 on a version first seen an hour ago defers while its assets upload',
      manifest_error(upstream_404, issue: '1', seen: fresh), Autobump::Abort
check 'the defer says the asset is not uploaded yet and when it escalates',
      $reason.match?(/not uploaded yet .* escalates if still missing on a run after \d{4}-\d\d-\d\d \d\d:\d\d UTC\z/),
      true
check 'a 404 on a version seen longer than the grace escalates',
      manifest_error(upstream_404, issue: '1', seen: stale), Autobump::Escalate
check 'a 404 escalates when the issue age cannot be read',
      manifest_error(upstream_404, issue: '1', seen: nil), Autobump::Escalate

upstream_403 = <<~LOG
  >>> Downloading 'https://upstream.example/pkg-1.1.tar.gz'
  ERROR 403: Forbidden.
LOG
check 'a 403 escalates however fresh the version is',
      manifest_error(upstream_403, issue: '1', seen: fresh), Autobump::Escalate
check 'a 404 plus a local defect escalates however fresh the version is',
      manifest_error("#{upstream_404}error sourcing ebuild\n", issue: '1', seen: fresh), Autobump::Escalate
check 'a mirror 404 plus upstream timeout still defers on a fresh version',
      manifest_error(mirror_404_then_timeout, issue: '1', seen: fresh), Autobump::Abort
check 'a local manifest defect escalates on a fresh version',
      manifest_error("Permission denied\n", issue: '1', seen: fresh), Autobump::Escalate

check 'an op-timeout defers regardless of the log',
      manifest_error(upstream_404, code: 124), Autobump::Abort

puts '----'
puts "distfiles_outcome: #{$fail.zero? ? 'all passed' : "#{$fail} failed"}"
exit($fail.zero? ? 0 : 1)
