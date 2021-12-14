.data
    n:		.word	5
    lbracket:	.string	"["
    rbracket: 	.string	"]\n"
    comma: 	.string	","

    iformat: 	.string	"%d"

.text

.global main
main:
    addi	sp, sp, -4
    sw 		ra, 0(sp)

    lw 		t0, n
    slli 	t0, t0, 2
    sub 	sp, sp, t0

    # count bits
    lw 		a0, n
    mv 		a1, sp
    call 	count_bits

    # print result
    mv 		a0, sp
    lw 		a1, n
    slli	a1, a1, 2
    call	print

    # restore sp
    lw 		t0, n
    slli	t0, t0, 2
    add		sp, sp, t0

    # restore ra
    lw 		ra, 0(sp)
    addi 	sp, sp, 4

    # exit
    li 		a0, 0
    ret

popcount:
    srli	t0, a0, 1
    li		t1, 0x55555555
    and		t0, t0, t1
    sub		a0, a0, t0
    li		t1, 0x33333333
    srli	t2, a0, 2
    and		t2, t2, t1
    and		a0, a0, t1
    add		a0, a0, t2
    srli	t0, a0, 4
    add		a0, a0, t0
    li		t0, 0x0f0f0f0f
    and		a0, a0, t0
    li		t0, 0x01010101
    mul		a0, a0, t0
    srli	a0, a0, 24
    ret

count_bits:
    addi 	sp, sp, -4
    sw 		ra, 0(sp)

    # base address of the array
    mv 		s0, a1
    # n
    mv 		s1, a0
    # i
    li 		s3, 0

loop:
    mv 		a0, s3
    call	popcount
    sw 		a0, 0(s0)

    addi	s3, s3, 1
    addi	s0, s0, 4
    bgt 	s1, s3, loop

    lw 		ra, 0(sp)
    addi 	sp, sp, 4
    ret

print:
    addi	sp, sp, -4
    sw 		ra, 0(sp)

    # base address of the array
    mv		s0, a0
    # boundary
    mv 		s1, a1
    add		s1, s1, s0

    # print left bracket
    la		a0, lbracket
    call	printf

    # print first number
    la 		a0, iformat
    lw 		a1, 0(s0)
    call	printf

    addi s0, s0, 4
    ble 	s1, s0, print_end

print_conti:
    # print comma
    la 		a0, comma
    call	printf

    # print number
    la 		a0, iformat
    lw 		a1, 0(s0)
    call 	printf

    addi 	s0, s0, 4
    bgt 	s1, s0, print_conti

print_end:
    # print right bracket and line break
    la 		a0, rbracket
    call 	printf

    lw 		ra, 0(sp)
    addi 	sp, sp, 4
    ret
