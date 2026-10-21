# @summary ovadm's own version, read from its metadata.json
#
# Read rather than hardcoded: the release workflow refuses a tag that
# disagrees with metadata.json, so the file is the source of truth.
#
# @return [String] the version, or `unknown` when metadata.json has none
function ovadm::version() >> String {
  $metadata = file::read("${module_directory('ovadm')}/metadata.json")
  $version_match = $metadata.match(/"version"\s*:\s*"([^"]+)"/)
  $version_match ? {
    undef   => 'unknown',
    default => $version_match[1],
  }
}
