NASMFLAGS = -f elf64 -w+all -w+error -w-unknown-warning -w-reloc-rel
LDFLAGS = -pie -I /lib64/ld-linux-x86-64.so.2 --fatal-warnings

discrete_fractal: discrete_fractal.o
	ld $(LDFLAGS) -o $@ $<

discrete_fractal.o: discrete_fractal.asm
	nasm $(NASMFLAGS) -o $@ $<

test: discrete_fractal
	./test.sh

clean:
	rm -f discrete_fractal discrete_fractal.o

.PHONY: test clean
