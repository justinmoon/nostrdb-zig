pkill ws-contacts-server

zig build ws-contacts-server -Doptimize=Debug

./zig-out/bin/ws-contacts-server --url wss://relay.damus.io --origin https://nostrdb-ssr.local --port 8085 --limit 20 --timeout 20000

open http://localhost:8085/
