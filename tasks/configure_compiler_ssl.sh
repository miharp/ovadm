#!/bin/bash
set -euo pipefail

export PATH="/opt/puppetlabs/bin:$PATH"

# Configure the puppetserver webserver to use SSL certs obtained from the
# Puppet CA (via puppet agent) rather than a self-generated CA.
# Must be run after puppet agent has fetched its cert and before puppetserver
# starts for the first time.

certname=$(puppet config print certname 2>/dev/null || hostname -f)
ssldir=$(puppet config print ssldir 2>/dev/null || echo '/etc/puppetlabs/puppet/ssl')

ssl_cert="${ssldir}/certs/${certname}.pem"
ssl_key="${ssldir}/private_keys/${certname}.pem"
ssl_ca_cert="${ssldir}/certs/ca.pem"
ssl_crl="${ssldir}/crl.pem"

webserver_conf='/etc/puppetlabs/puppetserver/conf.d/webserver.conf'

cat > "$webserver_conf" <<HOCON
webserver: {
    access-log-config: /etc/puppetlabs/puppetserver/request-logging.xml
    client-auth: want
    ssl-host: 0.0.0.0
    ssl-port: 8140
    ssl-cert: ${ssl_cert}
    ssl-key: ${ssl_key}
    ssl-ca-cert: ${ssl_ca_cert}
    ssl-crl-path: ${ssl_crl}
}
HOCON

# Disable the CA service so this node doesn't act as a CA
ca_cfg='/etc/puppetlabs/puppetserver/services.d/ca.cfg'
sed -i \
  -e 's|^puppetlabs.services.ca.certificate-authority-service/|#puppetlabs.services.ca.certificate-authority-service/|' \
  -e 's|^#puppetlabs.services.ca.certificate-authority-disabled-service/|puppetlabs.services.ca.certificate-authority-disabled-service/|' \
  "$ca_cfg"

# Remove any pre-generated CA directory to prevent accidental CA startup
rm -rf /etc/puppetlabs/puppetserver/ca

printf '{"status":"success","certname":"%s","ssl_cert":"%s"}\n' \
  "$certname" "$ssl_cert"
