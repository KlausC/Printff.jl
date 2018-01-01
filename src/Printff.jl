__precompile__(true)

module Printff


# the implementations here is copied from
# what is left in base/printf.jl, and uses the utility there

export @printf, @sprintf
export format, printf, sprintf

import Base.Printf: is_str_expr, fix_dec, DIGITS, print_fixed, decode_dec, decode_hex,
                   ini_hex, ini_HEX, print_exp_a, decode_0ct, decode_HEX, ini_dec, print_exp_e,
                   decode_oct, _limit

using Base.Printf: is_str_expr, gen_f, gen_e, gen_a, gen_g, gen_c, gen_s, gen_p, gen_d
using Unicode:  lowercase, textwidth

# copied from Base.Printf - amended by additional features:
# 1. argument positions %(\d+[$&])

function gen(s::AbstractString)
    args = []
    perm = Int[]
    ipos = 0
    blk = Expr(:block, :(local neg, pt, len, exp, do_out, args))
    for x in parse(s)
        if isa(x,AbstractString)
            push!(blk.args, :(write(out, $(length(x)==1 ? x[1] : x))))
        else
            pos = x[1]
            if pos == 0
                ipos += 1
                pos = ipos
            end
            c = lowercase(x[end])
            f = c=='f' ? gen_f :
                c=='e' ? gen_e :
                c=='a' ? gen_a :
                c=='g' ? gen_g :
                c=='c' ? gen_c :
                c=='s' ? gen_s :
                c=='p' ? gen_p :
                         gen_d
            arg, ex = f(x[2:end]...)
            push!(args, arg)
            push!(perm, pos)
            push!(blk.args, ex)
        end
    end
    push!(blk.args, :nothing)
    return args, blk, perm
end

### printf format string parsing ###

function parse(s::AbstractString)
    # parse format string into strings and format tuples
    reqpos = -1
    list = []
    i = j = start(s)
    j1 = 0 # invariant: j1 == prevind(s, j)
    while !done(s,j)
        c, k = next(s,j)
        if c == '%'
            i > j1 || push!(list, s[i:j1])
            flags, width, precision, conversion, k, pos = parse1(s,k)
            '\'' in flags && throw(ArgumentError("printf format flag ' not yet supported"))
            conversion == 'n'    && throw(ArgumentError("printf feature %n not supported"))
            pos != 0 && conversion == '%' && ( conversion = 's' )
            if conversion == '%'
                push!(list, "%")
            else
                pos == 0 && reqpos > 0 && throw(ArgumentError("argument positions required"))
                pos > 0 && reqpos == 0 && throw(ArgumentError("argument positions not allowed"))
                reqpos = ifelse(pos == 0, 0, 1)
                push!(list, (pos,flags,width,precision,conversion))
            end
            i = k
        end
        j1 = j
        j = k
    end
    i > endof(s) || push!(list, s[i:end])
    # coalesce adjacent strings
    i = 1
    while i < length(list)
        if isa(list[i],AbstractString)
            for outer j = i+1:length(list)
                if !isa(list[j],AbstractString)
                    j -= 1
                    break
                end
                list[i] *= list[j]
            end
            deleteat!(list,i+1:j)
        end
        i += 1
    end
    return list
end

## parse a single printf specifier ##

# printf specifiers:
#   %                       # start
#   (\d+\[$&])?             # arg position
#   [\-\+#0' ]*             # flags
#   (\d+)?                  # width
#   (\.\d*)?                # precision
#   (h|hh|l|ll|L|j|t|z|q)?  # modifier (ignored)
#   [diouxXeEfFgGaAcCsSp%]  # conversion

next_or_die(s::AbstractString, k) = !done(s,k) ? next(s,k) :
    throw(ArgumentError("invalid printf format string: $(repr(s))"))

function parse1(s::AbstractString, k::Integer)
    j = k
    width = 0
    precision = -1
    pos = 0
    c, k = next_or_die(s,k)
    # handle %%
    if c == '%'
        return "", width, precision, c, k, pos
    end
    # look for optional argument position
    ca, ka = c, k
    # if we didn't allow 0 as first char of position no traceback rqd.
    while '0' <= ca <= '9'
        pos = 10*pos + ca-'0'
        ca, ka = next_or_die(s,ka)
    end
    if ka != k
        if ca == '$' || ca == '&' # ending position number - continue format
            j = ka
            c, k = next_or_die(s,ka)
        elseif ca == '%'          # ending position and default format
            return "s", width, precision, ca, ka, pos
        else
            pos = 0 # backtrace
        end
    end

    # parse flags
    while c in "#0- + '"
        c, k = next_or_die(s,k)
    end
    flags = String(s[j:prevind(s,k)-1]) # exploiting that all flags are one-byte.
    # parse width
    while '0' <= c <= '9'
        width = 10*width + c-'0'
        c, k = next_or_die(s,k)
    end
    # parse precision
    if c == '.'
        c, k = next_or_die(s,k)
        if '0' <= c <= '9'
            precision = 0
            while '0' <= c <= '9'
                precision = 10*precision + c-'0'
                c, k = next_or_die(s,k)
            end
        end
    end
    # parse length modifer (ignored)
    if c == 'h' || c == 'l'
        prev = c
        c, k = next_or_die(s,k)
        if c == prev
            c, k = next_or_die(s,k)
        end
    elseif c in "Ljqtz"
        c, k = next_or_die(s,k)
    end
    # validate conversion
    if !(c in "diouxXDOUeEfFgGaAcCsSpn")
        throw(ArgumentError("invalid printf format string: $(repr(s))"))
    end
    # TODO: warn about silly flag/conversion combinations
    flags, width, precision, c, k, pos
end

function _printf(macroname, io, fmt, args)
    if isa(fmt, Expr) && fmt.head == :macrocall && fmt.args[1] == Symbol("@raw_str")
        fmt = fmt.args[end]
    end

    isa(fmt, AbstractString) ||
        throw(ArgumentError("$macroname: format must be a plain static or raw string (no interpolation or prefix)"))
    sym_args, blk, perm = gen(fmt)
    args = args[perm]
    has_splatting = false
    for arg in args
       if isa(arg, Expr) && arg.head == :...
          has_splatting = true
          break
       end
    end

    #
    #  Immediately check for corresponding arguments if there is no splatting
    #
    if !has_splatting && length(sym_args) != length(args)
       throw(ArgumentError("$macroname: wrong number of arguments ($(length(args))) should be ($(length(sym_args)))"))
    end

    for i = length(sym_args):-1:1
        var = sym_args[i].args[1]
        if has_splatting
           pushfirst!(blk.args, :($var = G[$i]))
        else
           pushfirst!(blk.args, :($var = $(esc(args[i]))))
        end
    end

    #
    #  Delay generation of argument list and check until evaluation time instead of macro
    #  expansion time if there is splatting.
    #
    if has_splatting
       x = Expr(:call,:tuple,args...)
       pushfirst!(blk.args,
          quote
             G = $(esc(x))
             if length(G) != $(length(sym_args))
                throw(ArgumentError($macroname,": wrong number of arguments (",length(G),") should be (",$(length(sym_args)),")"))
             end
          end
       )
    end

    pushfirst!(blk.args, :(out = $io))
    Expr(:let, Expr(:block), blk)
end


"""
    @printf([io::IOStream], "%Fmt", args...)

Print `args` using C `printf` style format specification string, with some caveats:
`Inf` and `NaN` are printed consistently as `Inf` and `NaN` for flags `%a`, `%A`,
`%e`, `%E`, `%f`, `%F`, `%g`, and `%G`. Furthermore, if a floating point number is
equally close to the numeric values of two possible output strings, the output
string further away from zero is chosen.

Optionally, an `IOStream`
may be passed as the first argument to redirect output.

# Examples
```jldoctest
julia> @printf("%f %F %f %F\\n", Inf, Inf, NaN, NaN)
Inf Inf NaN NaN\n

julia> @printf "%.0f %.1f %f\\n" 0.5 0.025 -0.0078125
1 0.0 -0.007813
```
"""
macro printf(args...)
    isempty(args) && throw(ArgumentError("@printf: called with no arguments"))
    if isa(args[1], AbstractString) || is_str_expr(args[1])
        _printf("@printf", :STDOUT, args[1], args[2:end])
    else
        (length(args) >= 2 && (isa(args[2], AbstractString) || is_str_expr(args[2]))) ||
            throw(ArgumentError("@printf: first or second argument must be a format string"))
        _printf("@printf", esc(args[1]), args[2], args[3:end])
    end
end

"""
    @sprintf("%Fmt", args...)

Return `@printf` formatted output as string.

# Examples
```jldoctest
julia> s = @sprintf "this is a %s %15.1f" "test" 34.567;

julia> println(s)
this is a test            34.6
```
"""
macro sprintf(args...)
    isempty(args) && throw(ArgumentError("@sprintf: called with zero arguments"))
    isa(args[1], AbstractString) || is_str_expr(args[1]) ||
        throw(ArgumentError("@sprintf: first argument must be a format string"))
    letexpr = _printf("@sprintf", :(IOBuffer()), args[1], args[2:end])
    push!(letexpr.args[2].args, :(String(take!(out))))
    letexpr
end

##### formatting functions                    

function _format(fmt::AbstractString)
    sym_args, blk, perm = gen(fmt)
    @gensym format
    @gensym sformat
    fun1 = :($format(out::IO) = nothing)
    alist = fun1.args[1].args 
    if isperm(perm)
        append!(alist, sym_args[invperm(perm)])
    else
        fargs, assi = permute_args(sym_args, perm)
        append!(alist, fargs)
        prepend!(blk.args, assi)
    end
    fun1.args[2].args[2] = blk
    
    #=
    # providing default first argument
    fun2 = :($format() = $format(STDOUT))
    append!(fun2.args[1].args, alist[3:end])
    append!(fun2.args[2].args[2].args, alist[3:end])
    
    # like sprintf - output to string
    fun3 = :($sformat() = begin io = IOBuffer(); $format(io); String(take!(io)) end)
    append!(fun3.args[1].args, alist[3:end])
    append!(fun3.args[2].args[2].args[4].args, alist[3:end])
    =#
    eval(fun1)
    # eval(fun2), eval(fun3)
end

function permute_args(sym, perm)
    length(perm) > 0 || throw(ArgumentError("empty permutation"))
    n = maximum(perm)
    r = 1:n
    r ⊆ perm || throw(ArgumentError("invalid permutation '$perm'"))
    targs = Vector(uninitialized, n)
    fill!(targs, Any)
    for (i, s) in zip(perm, sym)
        targs[i] = typeintersect(targs[i], eval(s.args[2])) 
    end
    fargs = Vector(uninitialized, n)
    for i in r
        @gensym a
        ti = targs[i]
        ti == Union{} && throw(ArgumentError("incompatible types for pos $i"))
        fargs[i] = :($a::$(targs[i]))
    end
    assi = Vector(uninitialized, length(perm))
    for (j, i) in enumerate(perm)
        assi[j] = :($(sym[j].args[1]) = $(fargs[i].args[1])) 
    end
    fargs, assi
end

function format(fmt::AbstractString)
    global ALL_FORMATS
    get!(ALL_FORMATS, fmt) do
        f = _format(fmt)
    end
end

printf(io::IO, fmt::Function, args...) = Base.invokelatest(fmt, io, args...)
printf(fmt::Function, args...) = printf(STDOUT, args...)
function sprintf(fmt::Function, args...)
    io = IOBuffer()
    printf(io, args...)
    String(take!(io))
end

printf(io::IO, fmt::AbstractString, args...) = printf(io, format(fmt), args...)
printf(fmt::AbstractString, args...) = printf(STDOUT, fmt, args...)
sprintf(fmt::AbstractString, args...) = sprintf(format(fmt), args)

const ALL_FORMATS = Dict{String, Function}()

end # module
