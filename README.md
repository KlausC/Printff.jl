# Printff

[![Build Status](https://travis-ci.org/KlausC/Printff.jl.svg?branch=master)](https://travis-ci.org/KlausC/Printff.jl)
[![Coverage Status](https://coveralls.io/repos/KlausC/Printff.jl/badge.svg?branch=master&service=github)](https://coveralls.io/github/KlausC/Printff.jl?branch=master)
[![codecov.io](http://codecov.io/github/KlausC/Printff.jl/coverage.svg?branch=master)](http://codecov.io/github/KlausC/Printff.jl?branch=master)

The purpose of this Package is to extend the stdlib/Printf package with further
format options.
If finished, it should be able to replace stdlib/Printf.

### New functionality

#### 1. All format specifiers in format strings may have an additional argument position number.

Rationale: When format strings are translated to other natural languages, sometimes the order
of the variable arguments must be changed.

Example: `@sprintf "%2&d %1&d" 41 42` results in `"42 41`.

#### 2. Functions `printf` and `sprintf` may be used instead of macros `@printf` and `@sprintf`.

Rationale: The format strings may be available in string variables or the result of macro
expansions of strings with embedded interpolation. This is not supported by the
macro-implementation.

Example: `printf(@tr"Name: %s Salary: %.2f", a, b)` assumung tr_str is a macro which replaces the input with another language.

#### 3. New function `format(::String) -> Function(::IO, args...)`

The format string is represented as a function, with appropriate argument number and type.
The first argument is an output device.
For each different format string, the function is generated once by parsing the format string.
The code block of the function is the same as generated for the macros.
The permanent storage of the functions allows to restrict the format-parsing to once per
runtime as is the case for macro implementation.

Example: `form_1 = format("%20s %g"); ... ; form_1(STDOUT, "hello", 99.8)`

