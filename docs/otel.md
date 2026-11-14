# Spans from the entity server

`transports/csrc/otel_span.h` is the span half of the engine's `open_telemetry` module in C99, and the
guest `interactor-otel-guest` is the same module for scripts. A hot loop records a finished span into a
fixed ring of 4,096 records, which costs one struct copy and no allocation. `otel_flush` writes one
OTLP/JSON `resourceSpans` body as one line, and the server calls it only in the idle part of a tick.
A full ring drops the span and counts it.

## Turning it on

    ENTITY_OTEL=<file> OTEL_RESOURCE_ATTRIBUTES="k=v,k2=v2" entity_serve ...

The server then writes an `entity.run` span with a child `entity.tick` for every tick. The attributes
of a tick are `clients`, `packets_in`, `datagrams_out` and `tick`. Resource attributes come from the
standard `OTEL_RESOURCE_ATTRIBUTES`; the file holds one body a line for a sidecar to post. Without
`ENTITY_OTEL` the server does nothing new.

## What the collector wants

AppSignal's collector takes OTLP over HTTP as protobuf, not JSON, and reads its push key from the
resource attribute `appsignal.config.push_api_key`, not from a header. A sidecar that turns these lines
into protobuf, or an OpenTelemetry Collector that takes JSON and forwards, sits between the file and
AppSignal. That sidecar is not here.

## Check

`transports/test/otel_span_witness.cpp` holds the properties, built on witness-cpp: a flush is one
balanced JSON line whatever the strings hold, every span has a 16-hex id and a shared 32-hex trace and
names its parent, times are the monotonic times plus one offset, and a full ring drops and counts.
Two planted-false properties must be caught. A second build with `-DOTEL_PLANT_NOCLEAN`, which skips
the string cleaning, must fail the first property; CTest runs it with `WILL_FAIL`.

    cmake -S transports/test -B build && cmake --build build && ctest --test-dir build
