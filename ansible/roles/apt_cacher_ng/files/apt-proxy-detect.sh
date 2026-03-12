#!/bin/bash
# Detect whether apt-cacher-ng is reachable and use it as a proxy.
if nc -w1 -z "apt-cacher-ng" 3142 2>/dev/null; then
  echo -n "http://apt-cacher-ng:3142"
else
  echo -n "DIRECT"
fi
