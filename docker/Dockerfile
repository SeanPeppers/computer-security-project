# Test machine: a plain Debian 13 box with root SSH (password) and an open Docker API on 2375.
FROM debian:13

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       openssh-server docker.io docker-cli iptables ca-certificates procps iproute2 curl less nano \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /run/sshd \
    && rm -f /etc/ssh/ssh_host_* \
    && sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/; s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config

COPY entrypoint.sh /usr/local/sbin/entrypoint.sh
RUN chmod 755 /usr/local/sbin/entrypoint.sh

EXPOSE 22 2375
ENTRYPOINT ["/usr/local/sbin/entrypoint.sh"]
