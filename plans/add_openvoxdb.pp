# @summary Add OpenVoxDB to an existing OpenVox Server deployment
#
# Installs and configures OpenVoxDB, then wires the OpenVox Server to use it
# for catalog storage, facts, and reports.
#
# OpenVoxDB requires a PostgreSQL database that must be provisioned before
# running this plan. Create the database and user, then pass the connection
# details as parameters.
#
# @param server_host
#   The OpenVox Server node
#
# @param db_password
#   PostgreSQL password for the OpenVoxDB database user
#
# @param puppetdb_host
#   The node to run OpenVoxDB on; defaults to server_host (co-located)
#
# @param db_name
#   PostgreSQL database name (default: puppetdb)
#
# @param db_user
#   PostgreSQL username (default: puppetdb)
#
# @param db_host
#   PostgreSQL server hostname, relative to puppetdb_host (default: localhost)
#
# @param db_port
#   PostgreSQL server port (default: 5432)
#
# @param store_reports
#   Enable report storage in OpenVoxDB (default: true)
#
# @param ovox_version
#   OpenVox Agent version (e.g. '8.26.2'); determines which major repo to enable
#   and pins openvox-agent on separate PuppetDB nodes
#
# @param ovox_server_version
#   Specific openvoxdb version to install (e.g. '8.13.0'); omit for latest
#
plan ovadm::add_openvoxdb(
  TargetSpec           $server_host,
  String[1]            $db_password,
  Optional[TargetSpec] $puppetdb_host       = undef,
  String[1]            $db_name             = 'puppetdb',
  String[1]            $db_user             = 'puppetdb',
  String[1]            $db_host             = 'localhost',
  Integer              $db_port             = 5432,
  Boolean              $store_reports       = true,
  Optional[String[1]]  $ovox_version        = undef,
  Optional[String[1]]  $ovox_server_version = undef,
  Optional[String[1]]  $apt_base_url        = undef,
  Optional[String[1]]  $yum_base_url        = undef,
) {
  $pdb_target = $puppetdb_host ? {
    undef   => $server_host,
    default => $puppetdb_host,
  }
  $co_located = $puppetdb_host =~ Undef

  run_plan('ovadm::subplans::openvoxdb', {
    'server_host'         => $server_host,
    'puppetdb_host'       => $pdb_target,
    'co_located'          => $co_located,
    'db_password'         => $db_password,
    'db_name'             => $db_name,
    'db_user'             => $db_user,
    'db_host'             => $db_host,
    'db_port'             => $db_port,
    'store_reports'       => $store_reports,
    'ovox_version'        => $ovox_version,
    'ovox_server_version' => $ovox_server_version,
    'apt_base_url'        => $apt_base_url,
    'yum_base_url'        => $yum_base_url,
  })

  out::message('OpenVoxDB installation and configuration complete.')
}
