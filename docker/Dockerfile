FROM rockylinux/rockylinux:9-ubi-init
# java-21 is a supported OpenVox runtime. Install it explicitly: without it,
# openvox-server's install pulls whatever java dnf picks (java 25 on current
# Rocky 9), which OpenVox rejects. The image stands in for a host whose Java the
# operator manages, matching ovadm's precheck-not-install stance.
RUN dnf install -y -q ca-certificates hostname java-21-openjdk-headless && dnf clean all
