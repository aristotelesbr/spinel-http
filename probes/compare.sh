#!/bin/sh
# Correctness gate: the probe transcript of examples/app.rb on CRuby and as
# a Spinel binary must be identical; a SIGTERM during a request must let it
# finish. Prints the widening warnings in the package's own code.
#
#   probes/compare.sh
#   SPINEL=path/to/spinel RUBY=path/to/ruby probes/compare.sh
set -u
cd "$(dirname "$0")/.."
RUBY=${RUBY:-$HOME/.local/share/mise/installs/ruby/4.0.7/bin/ruby}
SPINEL=${SPINEL:-$HOME/Projects/spinel/spinel}
mkdir -p build results
status=0

wait_ready() {
  i=0
  while [ $i -lt 100 ]; do
    grep -q listening "$1" 2>/dev/null && return 0
    perl -e 'select(undef,undef,undef,0.1)'; i=$((i + 1))
  done
  echo "server did not start, see $1"; return 1
}

run_probe() { # name port command...
  name=$1; port=$2; shift 2
  IDLE=1 PORT=$port "$@" > "results/$name.server.out" 2> "results/$name.server.err" &
  pid=$!
  wait_ready "results/$name.server.out" && PORT=$port "$RUBY" probes/probe.rb > "results/$name.probe.txt" 2>&1
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
}

shutdown_check() { # name port command...
  name=$1; port=$2; shift 2
  PORT=$port "$@" > "results/$name.shutdown.out" 2>&1 &
  pid=$!
  wait_ready "results/$name.shutdown.out" || return 1
  PORT=$port "$RUBY" -rsocket -e 's = TCPSocket.new("127.0.0.1", ENV["PORT"].to_i); s.write("GET /slow HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n"); puts s.gets' > "results/$name.shutdown.client" 2>&1 &
  cpid=$!
  perl -e 'select(undef,undef,undef,0.1)'
  kill -TERM $pid
  wait $cpid; wait $pid
  if grep -q "200 OK" "results/$name.shutdown.client" && grep -q stopped "results/$name.shutdown.out"; then
    echo "$name: graceful shutdown OK"
  else
    echo "$name: graceful shutdown FAILED, see results/$name.shutdown.*"; status=1
  fi
}

"$SPINEL" --warn-widen examples/app.rb -o build/app > results/compile.log 2>&1 || {
  echo "compile failed, see results/compile.log"; exit 1; }
echo "widening warnings in http/: $(grep warning results/compile.log | grep -c ' http/')"

run_probe cruby 19610 "$RUBY" examples/app.rb
run_probe binary 19611 build/app
if diff results/cruby.probe.txt results/binary.probe.txt > results/probe.diff; then
  echo "probe: IDENTICAL ($(grep -c '^== ' results/cruby.probe.txt) sections)"
else
  echo "probe: DIFFERENT, see results/probe.diff"; status=1
fi
shutdown_check cruby 19612 "$RUBY" examples/app.rb
shutdown_check binary 19613 build/app
exit $status
