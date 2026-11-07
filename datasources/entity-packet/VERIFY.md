# Verifying the packet

Moved out of `README.md` when the forty-line rule went in. The README states the layout; this
page is how you check that everything downstream still agrees with it.

```sh
lake exe packet_demo    # Plausible roundtrip + size, 50000-vector sweep
lake exe packet_emit    # writes packet_golden.csv and the C and Python codecs

# the committed copies must be the ones the emitter writes
diff packet_golden.csv build/packet_golden.csv
diff xr_grid_entity_packet.h build/xr_grid_entity_packet.h
diff xr_grid_entity_packet.py build/xr_grid_entity_packet.py

# differential: the C the emitter wrote must produce the Lean bytes
cc -std=c11 -I build test/golden.c -o build/golden
./build/golden build/packet_golden.csv     # PACKET DIFFERENTIAL PASS

# differential: the engine's C++ XRGridEntityPacket.decode must match
godot --headless --script packet_diff.gd   # PACKET DIFFERENTIAL PASS

# differential: the Python the emitter wrote, run where it is vendored
cd ../../1-transport/ingest-python && pixi run check   # 64/64
```

Last run: Plausible clean, 50000/50000 roundtrip, the C++ decode matching the spec on 64
golden vectors, and the emitted C and Python encoders each matching all 64 byte for byte.

The two differentials are the point rather than the roundtrip. A roundtrip closing proves the
encoder and decoder here are inverses of each other; it says nothing about whether the engine
that has to read these bytes agrees. Assert the property where it is consumed.
