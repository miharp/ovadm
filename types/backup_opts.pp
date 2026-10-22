# @summary What `ovadm::backup` puts in the archive
#
# Every item is on unless switched off, so the default is everything a
# disaster recovery needs and a caller opts out of what it does not want.
#
# - `ca`: the CA directory, the server's own certificate and key, and
#   OpenVoxDB's copy of them
# - `config`: the rest of `/etc/puppetlabs/` (without `code/`) and the
#   services' environment files
# - `code`: what r10k deployed, as each environment's `.r10k-deploy.json`
#   and `hiera.yaml`, with `/etc/puppetlabs/r10k/`; `include_code_tree` on
#   the plan takes the directory too
type Ovadm::Backup_opts = Struct[{
  Optional[ca]     => Boolean,
  Optional[config] => Boolean,
  Optional[code]   => Boolean,
}]
