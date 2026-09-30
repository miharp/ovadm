FROM ubuntu:22.04
# A Puppet Server 7 host to upgrade to OpenVox 8, installed from Puppet's own
# repository the way such hosts were. Java 11 is what Puppet Server 7 ran on;
# the install-test job pins it as the default before upgrading.
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq \
 && apt-get install -y -qq systemd systemd-sysv curl ca-certificates hostname openjdk-11-jre-headless \
 && curl -fsSLo /tmp/puppet7-release.deb https://apt.puppet.com/puppet7-release-jammy.deb \
 && dpkg -i /tmp/puppet7-release.deb && rm /tmp/puppet7-release.deb \
 && apt-get update -qq \
 && apt-get install -y -qq puppetserver \
 && apt-get clean && rm -rf /var/lib/apt/lists/*
CMD ["/sbin/init"]
