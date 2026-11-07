# contract-entity-packet

The Lean 4 source of truth for the fabric's fixed-size, all-integral entity packet, with property tests and emitted codecs.

## What it is for

The packet carries no floats, so Lean models it exactly and Plausible roundtrip properties find codec gaps without an engine rebuild. `EntityPacket/Codec.lean` names each offset once; the encoder, the decoder and the C and Python emitters all read it. The emitted `xr_grid_entity_packet.h` and `xr_grid_entity_packet.py` are committed so a repository that vendors this one gets a codec without running Lean. Edit `Codec.lean` and replace them with what `packet_emit` writes rather than editing either by hand.

## Build, test and emit

```sh
lake exe packet_demo
lake exe packet_emit
```

`VERIFY.md` holds the differentials that keep the C codec, the Python codec and the engine in agreement with this specification.

## Licence

MIT; see `LICENSE`.
