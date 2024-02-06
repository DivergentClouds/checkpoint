# Checkpoint

## Notes

- Written in raw binary
- Looping and branching are done via checkpoints
  - Checkpoints are essentially runtime labels
- Arbitrarily many cells
  - Infinite number of in theory
- Each cell contains a single bit
- Cells are initialized to 0
- Memory pointer (MP) is initialized to 0
- Program counter (PC) is initialized to 0
- Checkpoint ID (ID) is initialized to 0
- Checkpoint offset is initialized to 0
- Mode is initialized to PC
- Halts if MP or PC go below 0
- Offset and ID may go below 0
- Reading from an undefined checkpoint is illegal behavior
- Separate IDs, Offsets, and checkpoints for MP and PC
- Order of operations happens bit by bit starting from most significant bit

## Operations

```
0000 0000
|||| ||||
+---------- Increment ID
 ||| ||||   |-----------------+ Increment offset
 +--------- Decrement ID      |
  || ||||                     |------- Swap between MP and PC checkpoint modes
  +-------- Increment MP      |
   | ||||   |-----------------+ Decrement offset
   +------- Decrement MP
     ||||
     +----- Flip bit at MP
      |||
      +---- Output bit at MP
       ||
       +--- Set checkpoint with ID to PC/MP + offset
        |
        +-- If bit at MP is 1:
              If in PC mode set PC to byte after checkpoint with ID
              If in MP mode set MP to the checkpoint with ID
```
