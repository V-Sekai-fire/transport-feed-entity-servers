# Swing-twist rotation in `Packet.rot`

`Packet.rot` is three Int16 at byte offset 52. They hold one rotation as a swing and a twist, not as a quaternion. The converters are in `EntityPacket/Codec.lean`, and each step has its own function, so reading `encodeRot` and `decodeRot` top to bottom is the specification.

## The three Int16

| Slot | Meaning | Scale |
| --- | --- | --- |
| `rot.1` | swing rotation vector, X component | 32767 per pi radians, linear |
| `rot.2.1` | swing rotation vector, Z component | 32767 per pi radians, linear |
| `rot.2.2` | twist about +Y | 65536 per full turn, circular |

One code is about 96 microradians in both scales. The slots are named `rot_x`, `rot_y` and `rot_z` in the emitted header. Slot 2 holds the swing Z component and slot 3 holds the twist about Y, so those names do not match the axes.

## The convention

`q = swing * twist`, and `Quat.mul a b` applies `b` first, as Godot's `a * b`. The twist is a turn about +Y. The swing is whatever remains, and its axis lies in the XZ plane.

Encoding, in order:

1. `twistOf` keeps only the Y and W components of `q` and normalizes them.
2. `swingOf` divides the twist out: `q * conj(twist)`. Its sign is fixed so that `w > 0`, and at `w = 0` so that `x > 0`, then `z > 0`.
3. `twistAngle` is `2 * atan2(y, w)` of the twist, in (-pi, pi].
4. `swingVector` turns the swing into `angle * axis`, keeping the X and Z parts. The angle is in [0, pi].
5. `swingCode` and `twistCode` scale and round. The twist code wraps, so pi and -pi share one code.

Decoding is the same chain backwards: `swingFromCodes`, `twistFromCode`, then `decodeRot` multiplies them.

## Why not a quaternion

Three Int16 hold three numbers. A unit quaternion has four components and one constraint, so it needs either a fourth field or a reconstruction of the largest component. Swing-twist stores the rotation directly, and a twist about the character's up axis is a quantity gameplay code reads.

Swing-twist does not remove the singularity. It moves it to a swing of exactly pi. There the swing axis and the twist cannot be told apart, and `swingOf` returns a swing with a canonical sign and a twist taken from whatever Y and W remain (the identity if both are under 1e-12). A rotation just either side of that point can land on antipodal swing codes. Each such code still decodes to a rotation within the error bound, and the half-turn cases in `rot_check` confirm that. The jump between antipodal codes is not measured.

## Basis

`Basis.cx`, `cy` and `cz` are Godot's `Basis.x`, `Basis.y` and `Basis.z`, the images of the three axes. `Basis.ofQuat` is the same formula as Godot's `Basis(Quaternion)`. `Basis.toQuat` picks its branch from the largest of the trace and the diagonal entries, so the divisor stays away from zero. `encodeRotBasis` is `encodeRot` of that quaternion. The input must be orthonormal with determinant +1.

## Worked examples

These are the values `rot_check` prints.

| Rotation | Codes |
| --- | --- |
| identity | `0 0 0` |
| 90 degrees about X | `16383 0 0` |
| 90 degrees about Z | `0 16383 0` |
| 90 degrees about Y | `0 0 16384` |

A 90 degree swing is half of pi, which is 16383.5 on the 32767 scale, so it rounds to 16383 in the float result. A 90 degree twist is a quarter of 65536 and gives 16384.

## Coordinate frames

The wire frame is Godot's: X right, Y up, -Z forward, right-handed. The slot names `rot_x`, `rot_y` and `rot_z` are positions in the wire, not axes, so the wire order stays as it is. Slot 1 is the swing about wire X, slot 2 the swing about wire Z, slot 3 the twist about wire Y.

An engine with another frame is a `Frame`: a signed permutation that says where each wire axis comes from. `encodeRotIn f` and `decodeRotIn f` convert at the edge and call `encodeRot` and `decodeRot` unchanged.

| Frame | Up | Forward | Handed | `det` |
| --- | --- | --- | --- | --- |
| `Frame.godot` | +Y | -Z | right | +1 |
| `Frame.unity` | +Y | +Z | left | -1 |
| `Frame.unreal` | +Z | +X | left | -1 |
| `Frame.blender` | +Z | +Y | right | +1 |

A rotation is an axial vector, so a left-handed frame flips the sign of the quaternion's vector part and leaves `w` alone. That is the only thing a rotation needs beyond what a position needs. Godot to Unity turns `(0.1, 0.2, 0.3, 0.4)` into `(-0.1, -0.2, 0.3, 0.4)`.

`Basis` here is defined by its columns, `cx`, `cy` and `cz`, which are Godot's `Basis.x`, `Basis.y` and `Basis.z`. An engine that stores a matrix by rows must transpose it before building a `Basis`.

## Precision

`Float` in Lean is IEEE 754 binary64, the same as `double` and Godot's `real_t` in a `precision=double` build. The reference converters therefore compute in double, and `rot_check` asserts that `1 + 2^-52 > 1` and `1 + 2^-53 == 1`. A port must use `double`. GDScript `float` is already 64-bit.

One code is about 96 microradians, and a single-precision `Quaternion` is already rounded by about 6e-8 before it reaches the converter. A float32 port would differ only where a value sits near a rounding boundary, by one code, but that is a statement about the arithmetic and has not been measured here.

`sqrt` and the four arithmetic operations are correctly rounded everywhere. `atan2`, `sin` and `cos` are not, so two platforms can disagree in the last bits of a result. A port is expected to match within one code, and a golden file should avoid ties. A 90 degree swing is 16383.5 on the swing scale and lands on 16383 here only by the float result.

Not done: no C, Python or GDScript converter is emitted, and nothing is checked against the engine's own `Basis`. The tolerance above is a design target until those exist.

## Verify

```sh
lake build rot_check
lake exe rot_check
```

It runs 100,013 rotations (100,000 pseudo-random and 13 special cases) and checks:

- the quaternion and the Basis round trips stay within 200 microradians (measured maximum 97 microradians, one code)
- the Basis path and the quaternion path agree within one code
- `q` and `-q` agree within one code
- the decoded quaternion has unit length
- the golden cases above
- for each of the four frames: the frame is a valid signed permutation, up is wire +Y and forward is wire -Z, the same physical rotation gives the same codes, a rotated vector agrees across frames, and both round trips hold in the engine frame

Planted defects must be caught, so a pass means the check can fail: swing and twist applied in the wrong order, the twist code dropped, a 1 milliradian offset, a left-handed frame without the `det` sign, and the wrong frame.
