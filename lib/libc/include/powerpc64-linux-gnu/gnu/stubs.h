/* This file is automatically generated.
   This file selects the right generated file of `__stub_FUNCTION' macros
   based on the architecture being compiled for.  */

#include <bits/wordsize.h>

#if __WORDSIZE == 32
# include <gnu/stubs-32.h>
#endif
#if __WORDSIZE == 64 && _CALL_ELF != 2
# include <gnu/stubs-64-v1.h>
#endif
#if __WORDSIZE == 64 && _CALL_ELF == 2
# include <gnu/stubs-64-v2.h>
#endif