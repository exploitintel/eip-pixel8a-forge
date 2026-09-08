#!/system/bin/sh
# Compatibility entry point. The qualified Pixel host lifecycle owns current
# Wi-Fi table discovery and the exact bridge policy rules.
exec /data/docker/bin/hostctl start
