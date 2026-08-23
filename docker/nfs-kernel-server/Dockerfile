FROM ubuntu:22.04

# Kernel NFS server image, self-hostable replacement for gists/nfs-server
# (currently deployed digest-pinned; see nfsKernelServer.image in values.yaml
# and templates/nfs/nfs-kernel-deploy.yaml).
#
# Build & ship (once a registry reachable from the cluster exists):
#   docker build -t <registry>/<prefix>/nfs-kernel-server:1.0.0 .
#   docker push <registry>/<prefix>/nfs-kernel-server:1.0.0
# then set nfsKernelServer.image accordingly (pin by digest).
#
# Runtime contract (must stay in sync with the chart):
#   - reads /etc/exports (chart mounts it from a ConfigMap)
#   - NFS_SERVER_THREAD_COUNT  -> rpc.nfsd thread count
#   - NFS_PORT_MOUNTD=20048, NFS_PORT_STATD_IN/OUT=662
#   - NFS_VERSION=3            -> v3-only (v4 disabled)
#   - needs privileged: true and /lib/modules mounted read-only

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        nfs-kernel-server \
        nfs-common \
        mount \
    && rm -rf /var/lib/apt/lists/*

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 2049/tcp 2049/udp 111/tcp 111/udp 662/tcp 662/udp 20048/tcp 20048/udp

ENTRYPOINT ["/entrypoint.sh"]
