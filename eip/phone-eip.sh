#!/system/bin/sh
# Launch the operator container that drives the v4 compose stack on this phone.
# --network host so the UI's published 127.0.0.1:7171 is the same loopback the
# operator (and verify.sh) sees. The state root and repo are bind-mounted at
# their real phone paths so compose resolves identical paths on both sides.
if [ "${1:-}" = up ]; then
  install -d -m 0755 /data/docker/eip-cve-control
fi

export DOCKER_HOST=unix:///data/docker/run/docker.sock
exec /data/docker/bin/docker run --rm -i --network host \
  -e DOCKER_HOST=unix:///var/run/docker.sock \
  -v /data/docker/run/docker.sock:/var/run/docker.sock \
  -v /data/eip-cve:/data/eip-cve \
  -v /data/eip-cve-src:/data/eip-cve-src \
  -v /data/eip-cve-ops:/data/eip-cve-ops \
  --entrypoint /data/eip-cve-ops/entry.sh \
  eip-operator-shell:phone "$@"
