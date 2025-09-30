GNET
Starting stress test with:
- 100 concurrent clients
- 10 seconds duration
- 100 bytes message size
- Server address: localhost:9000

RPS: 95 | Avg Latency: 0.77 ms | Total: 1238062 | Success: 1238062 | Failed: 0d: 0

Test completed!
Duration: 11.00 seconds
Total Requests: 1238062
Successful Requests: 1238062
Failed Requests: 0
Average Latency: 0.77 ms
Average RPS: 112520.37

LOOM
Starting stress test with:
- 100 concurrent clients
- 10 seconds duration
- 100 bytes message size
- Server address: localhost:9000

RPS: 96 | Avg Latency: 0.56 ms | Total: 1698976 | Success: 1698976 | Failed: 0d: 0

Test completed!
Duration: 11.00 seconds
Total Requests: 1698976
Successful Requests: 1698976
Failed Requests: 0
Average Latency: 0.56 ms
Average RPS: 154413.48


WRK Bench Single Threaded
wrk -t1 -c1000 -d5m http://127.0.0.1:8443
Tether Single Threaded:
Running 5m test @ http://127.0.0.1:8443/api/test
  1 threads and 1000 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     3.23ms  828.22us  14.03ms   81.50%
    Req/Sec   157.39k    19.37k  190.00k    62.89%
  46981203 requests in 5.00m, 4.51GB read
Requests/sec: 156571.31
Transfer/sec:     15.38MB

GNET Single Threaded:
Running 5m test @ http://127.0.0.1:8443
  1 threads and 1000 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     3.74ms    6.43ms 349.39ms   99.63%
    Req/Sec   154.56k    19.16k  234.14k    85.84%
  46123967 requests in 5.00m, 4.47GB read
Requests/sec: 153728.91
Transfer/sec:     15.25MB

ZZZ Single Threaded:
Running 5m test @ http://127.0.0.1:8443/api/test
  1 threads and 1000 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     6.26ms   14.68ms   1.25s    99.91%
    Req/Sec   150.54k    12.62k  177.11k    76.47%
  44931210 requests in 5.00m, 4.48GB read
Requests/sec: 149766.24
Transfer/sec:     15.28MB

Express.js Single Threaded:
Running 5m test @ http://127.0.0.1:8443/api/test
  1 threads and 1000 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    62.00ms   14.93ms   1.98s    93.90%
    Req/Sec    15.77k     0.93k   17.17k    80.67%
  4709287 requests in 5.00m, 1.84GB read
  Socket errors: connect 0, read 2013, write 126, timeout 619
  Non-2xx or 3xx responses: 4709287
Requests/sec:  15693.13
Transfer/sec:      6.27MB
