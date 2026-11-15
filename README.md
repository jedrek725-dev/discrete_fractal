# discrete_fractal: L-system string generator in x86-64 assembly

A program written in pure x86-64 assembly (NASM, Linux syscalls only, no libc)
that expands ASCII fractals defined by string-rewriting rules (an L-system).
It reads an initial string and replacement rules, applies `n` rounds of
rewriting, where `n` can be as large as 2³² − 1, and prints the result.

The project was built for a systems programming course at the University of
Warsaw. The main grading criterion was **speed**, followed by section sizes
and memory usage. Comments in the code are in Polish, as the course requires.

## Example

```
$ printf 'A\nAAB\nBA\n' | ./discrete_fractal 4
ABAABABA
```

Line 1 is the initial string. Each following line is a rule: the first
character is the symbol being replaced and the rest of the line is what replaces
it (`A → AB`, `B → A`). Four iterations produce the Fibonacci word shown above.

## How it works

The naive approach rebuilds the whole string in every iteration, so its cost
grows with `n` even when most of the work disappears. This implementation never
builds the intermediate strings. Instead it walks the derivation tree
depth-first with its own explicit stack and writes final symbols straight into
the output buffer. Four shortcuts keep the running time proportional to the
**length of the output** rather than to the number of iterations:

1. **Terminal symbols.** A symbol with no rule (or with the identity rule
   `s → s`) is written out at once, however many iterations remain.
2. **Death times.** For every symbol the program precomputes after how many
   iterations its expansion becomes empty, as a fixed point over the rules.
   Subtrees that vanish are skipped in O(1).
3. **Block copy at depth 1.** When a symbol has one iteration left, the text of
   its rule is copied as a block with 16-byte SSE moves.
4. **Chain jumping with cycle detection.** Once more iterations remain than the
   largest death time, only "immortal" successors survive. If a rule has exactly
   one immortal successor, the symbol simply turns into it. Such chains are
   jumped over, and when a chain enters a cycle the remaining steps are reduced
   modulo the cycle length. This makes `n = 4 294 967 295` as cheap as a small
   `n`. The last jump from each symbol is memoised.

### Memory

- The input, the output and the traversal stack each live in their own region
  allocated with `mmap` and grown by doubling with `mremap`, so the only limit
  is available memory.
- All lookup tables (death times, rule addresses and lengths, jump memo) sit in
  a single frame on the process stack. The binary has only a `.text` section.
- Every region is explicitly released with `munmap` on both success and error
  paths.

### Robustness

The program validates the argument count, the numeric argument (overflow above
2³² − 1 included), every input character, duplicate rules and the trailing
newline. It also checks the result of every system call and handles partial
writes. It exits with code `0` on success and `1` on any error.

## Building and running

Requires Linux x86-64, `nasm` and `ld`.

```bash
nasm -f elf64 -w+all -w+error -w-unknown-warning -w-reloc-rel \
     -o discrete_fractal.o discrete_fractal.asm
ld -pie -I /lib64/ld-linux-x86-64.so.2 --fatal-warnings \
   -o discrete_fractal discrete_fractal.o

printf 'A\nAAB\nBA\n' | ./discrete_fractal 4
```
