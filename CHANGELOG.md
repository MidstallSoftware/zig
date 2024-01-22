## TODO Builtins
- [ ] `@memmove`
- [ ] `@pow`
- [ ] `@expect`
- [ ] `@cold`



# `@memmove`
## TODO
- [ ] Comptime

## Description
This builtin provides `llmv.memmove`. Basically `@memcpy` just with no alias check and len is calculated from the source.

# `@pow`
## TODO
- [x] Comptime
- [ ] Comptime Powi

## Description
This builtin provides both the `llvm.pow` and `llvm.powi`. RHS must be a float type or vector float. LHS can be either an Int, Float
Int Vector, or Float Vector, and we correctly choose whether to use `powi` or `pow`.
