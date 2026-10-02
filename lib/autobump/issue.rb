# frozen_string_literal: true
require 'shellwords'
require 'time'
module Autobump
  # Resolve a bump issue (nvchecker) to (pkg, newver) from its "[nvchecker] cat/pkg can
  # be bump to X" title.
  class Issue
    def self.resolve(cfg, issue)
      # shellescape both interpolations; the only user-derived value here is the issue
      # token, and cli tightens it to bare digits before we ever get here.
      title = `gh issue view #{issue.to_s.shellescape} --repo #{cfg.upstream_repo.shellescape} --json title --jq .title 2>/dev/null`.strip
      raise "cannot read issue ##{issue}" if title.empty?
      pkg = title[%r{^\[nvchecker\] ([a-z0-9-]+/[A-Za-z0-9_+-]+) can be bump to }, 1]
      # version class includes '+' (build metadata, e.g. 1.0+r1) to match the pkg class
      ver = title[/ can be bump to ([A-Za-z0-9._+-]+)$/, 1]
      raise "cannot parse issue title: #{title}" unless pkg && ver
      [pkg, ver]
    end

    # bumpbot retitles an open issue to a newer version instead of opening another, so the
    # last title change, not the creation, is when the issue started naming its version.
    SEEN_QUERY = <<~GRAPHQL
      query($owner: String!, $name: String!, $number: Int!) {
        repository(owner: $owner, name: $name) {
          issue(number: $number) {
            createdAt
            timelineItems(itemTypes: [RENAMED_TITLE_EVENT], last: 1) {
              nodes { ... on RenamedTitleEvent { createdAt } }
            }
          }
        }
      }
    GRAPHQL

    # When the issue started naming the version it names now; nil when GitHub does not answer.
    def self.version_seen_at(cfg, issue)
      owner, name = cfg.upstream_repo.split('/', 2)
      out = IO.popen(['gh', 'api', 'graphql', '-f', "owner=#{owner}", '-f', "name=#{name}",
                      '-F', "number=#{issue}", '-f', "query=#{SEEN_QUERY}",
                      '--jq', '.data.repository.issue | .timelineItems.nodes[-1].createdAt // .createdAt'],
                     err: File::NULL, &:read)
      $?.success? ? Time.iso8601(out.strip) : nil
    rescue ArgumentError, SystemCallError
      nil
    end
  end
end
