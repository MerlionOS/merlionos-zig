.text
.globl yieldCurrent
.type yieldCurrent, @function
yieldCurrent:
    int $0x81
    ret

.globl taskBootstrap
.type taskBootstrap, @function
taskBootstrap:
    mov %r13, %rsp
    call *%r12
1:
    cli
    hlt
    jmp 1b

.globl backgroundWorkerLoop
.type backgroundWorkerLoop, @function
backgroundWorkerLoop:
1:
    pause
    jmp 1b
